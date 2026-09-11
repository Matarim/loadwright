# frozen_string_literal: true

require "loadwright/errors"
require "loadwright/discovery/endpoint"

module Loadwright
  module Discovery
    # Turns `/api/v1/posts/{id}/comments` into `/api/v1/posts/4271/comments`.
    #
    # WHY THIS IS REQUIRED RATHER THAN NICE TO HAVE. OpenAPI examples carry
    # placeholder ids — `1`, `"string"`, `abc-123` — which 404 against a
    # freshly-seeded database. Without resolution most nested endpoints fail the
    # response validity gate, the whole run comes back `inconclusive`, and that is
    # the single most likely way a first real-world run produces nothing useful.
    #
    # Resolution order, per discovery-and-load-engine.md:
    #
    #   1. An explicit config.path_param_overrides entry — for slugs, UUIDs,
    #      composite keys, and external identifiers nothing can infer. First,
    #      because it is opt-in: reaching for it states a fact we inferred wrongly.
    #   2. A seeded record's identifier — the only source guaranteed to exist in
    #      the database being measured right now.
    #   3. An id captured during integration-spec recording — those requests
    #      demonstrably worked, though against a different database state.
    #   4. The OpenAPI example, last, because it is least likely to correspond to
    #      real data.
    #
    # If none resolve, the endpoint is SKIPPED and named. Sending a placeholder id
    # and then reporting the resulting 404 as a performance result is the specific
    # thing this class exists to prevent.
    class PathParamResolver
      Resolution = Struct.new(:path, :values, :sources, keyword_init: true) do
        def to_h = { path: path, values: values, sources: sources }
      end

      Unresolved = Struct.new(:endpoint, :params, keyword_init: true) do
        def detail
          "could not resolve #{params.map { |p| "{#{p}}" }.join(', ')}"
        end
      end

      # AN EXPLICIT OVERRIDE FIRST. It is opt-in and empty by default, so reaching for
      # it means the user has stated a fact the tool inferred wrongly -- and it used to
      # sit third, behind two inferences, which made it unreachable on exactly the APIs
      # it exists for. An API routing on a public guid got a primary key substituted,
      # 404'd every request, and the documented fix could not take effect.
      SOURCE_ORDER = %i[override seeded recorded example].freeze

      # Resource name -> the endpoints that asked for it. Lets the run say which key a
      # path parameter was looked up under, which is the half a silent miss hides.
      attr_reader :looked_up

      def initialize(config: Loadwright.configuration, seeded_ids: {}, unresolvable_parameters: [])
        @config = config
        @looked_up = {}
        # { "post" => [1, 2, 3] } — resource name to ids the seeder just created.
        @seeded_ids = seeded_ids
        @unresolvable_parameters = Array(unresolvable_parameters).map(&:to_s)
        @cursors = {}
      end

      def seeded_ids=(mapping)
        @seeded_ids = mapping
        @cursors = {}
      end

      # PARAMETERS THE SEEDER CONFIGURED AND COULD NOT FILL. `factory_map` `values:`
      # names how to address one resource per parameter; when not one seeded row could
      # produce a value, the honest answer is that the parameter is unresolved. The
      # answer it used to give was the resource's SHARED value -- a GUID handed to a
      # mount that routes on a number, on every request, reported as that endpoint's
      # 404. An explicit override still satisfies it, because an override is the user
      # stating a fact rather than the tool inferring one.
      def unresolvable_parameters=(names)
        @unresolvable_parameters = Array(names).map(&:to_s)
      end

      # Returns a Resolution, or an Unresolved. Deliberately not nil: an unresolved
      # endpoint carries WHICH param failed, which is what makes the report
      # actionable ("add post to factory_map") rather than a shrug.
      def resolve(endpoint, index: 0)
        return Resolution.new(path: endpoint.path, values: {}, sources: {}) unless endpoint.path_params?

        values = {}
        sources = {}
        missing = []

        endpoint.path_params.each do |param|
          candidate, source = candidates_for(endpoint, param, index)

          if candidate.nil?
            missing << param
          else
            values[param] = candidate
            sources[param] = source
          end
        end

        return Unresolved.new(endpoint: endpoint, params: missing) if missing.any?

        path = substitute(endpoint.path, values)

        # The choke point every source passes through. Whatever a substitution
        # produced, a path still carrying a placeholder is unresolved -- never a
        # request. A literal `{` in an outbound URL raises URI::InvalidURIError once
        # per request and reads as the endpoint being broken.
        return Unresolved.new(endpoint: endpoint, params: Endpoint.params_in(path).map(&:to_sym)) if
          path.include?("{")

        Resolution.new(path: path, values: values, sources: sources)
      end

      # THE SAME CARE FOR A QUERY PARAMETER THAT LOOKS LIKE AN IDENTIFIER.
      #
      # A recorded identifier in the PATH is treated as the weakest kind of evidence --
      # fourth in a deliberately ordered chain, behind an override and a seeded row --
      # because a spec's ids do not exist in the database being measured. The same
      # identifier in a QUERY STRING was treated as fact and replayed verbatim, which
      # is the same mistake with a different punctuation mark: the placeholder matches
      # nothing, the endpoint answers 404, and it reads as the endpoint being broken.
      #
      # Returns a seeded value for an identifier-shaped name, or nil. Nil is not a
      # failure here: the caller keeps the recorded value, because a request missing a
      # required parameter is a worse outcome than one carrying a stale id, and says
      # what it did.
      # AN OVERRIDE IS CONSULTED HERE TOO, and it was not -- which made the report's own
      # advice untrue. An unresolved identifier-shaped query parameter was told to use
      # path_param_overrides, and this resolver never read it, so the prescribed fix
      # could not affect the request. Same failure as 0.0.2's: the documented remedy
      # sitting behind a code path that could not reach it.
      #
      # It also answers the case that needs it. One resource can be addressed by a GUID
      # on one mount and a number on another -- `{resource_id}` and `resource_number`
      # both derive to "resource" -- and factory_map publishes one value per resource.
      # An override keyed by the PARAMETER NAME picks per parameter without disturbing
      # path segments that derive to the same resource.
      def resolve_query_param(name, index: 0)
        override = query_override_for(name, index)
        return override unless override.nil?
        return nil if unresolvable_parameter?(name)

        by_parameter = Array(@seeded_ids[name.to_s] || @seeded_ids[name.to_sym])
        unless by_parameter.empty?
          note_lookup(name.to_s, name)
          return by_parameter[index % by_parameter.length]
        end

        resource = resource_from_name(name)
        return nil if resource.nil?

        ids = Array(@seeded_ids[resource] || @seeded_ids[resource.to_sym])
        return nil if ids.empty?

        ids[index % ids.length]
      end

      # By bare parameter name only. The template-keyed form addresses a path, and a
      # query parameter has no template of its own to be keyed by.
      def query_override_for(name, index)
        overrides = @config.path_param_overrides
        value = overrides[name.to_sym] || overrides[name.to_s]
        return nil if value.nil? || value.is_a?(Hash)

        return value.call(index) if value.respond_to?(:call) && value.arity == 1
        return value.call if value.respond_to?(:call)

        value.is_a?(Array) ? value[index % value.length] : value
      end

      # True for `widget_id`, `account_guid`, `order_ref`. False for `view`, `page`,
      # `q` -- an ordinary filter is not an identifier and replaying it is exactly
      # right.
      def identifier_shaped?(name)
        !resource_from_name(name).nil?
      end

      # Seeded, and asked for by nobody. Either the factory_map key does not match what
      # any path parameter derives to, or no endpoint routes on it. Both are worth a
      # sentence: the first is a silent misconfiguration, and until now the run's only
      # symptom was requests carrying a recorded literal for no stated reason.
      def unconsumed_resources
        Array(@seeded_ids.keys).map(&:to_s).reject { |name| @looked_up.key?(name) }
      end

      def unconsumed_warning
        unused = unconsumed_resources
        return nil if unused.empty? || @looked_up.empty?

        "factory_map seeded #{unused.map(&:inspect).join(', ')} and no endpoint's path parameter " \
          "resolved to #{unused.length == 1 ? 'it' : 'them'}. A factory_map key is matched against a " \
          "name derived from the PATH PARAMETER, not from the factory: #{example_derivation}. The " \
          "names endpoints actually asked for were #{@looked_up.keys.map(&:inspect).sort.join(', ')} " \
          "-- rekey factory_map to one of those, or use path_param_overrides."
      end

      def example_derivation
        "`{widget_id}`, `{widget_guid}` and `{widget_number}` all look under \"widget\""
      end

      def to_h
        {
          seeded_resources: @seeded_ids.keys,
          resources_endpoints_asked_for: @looked_up.keys.sort,
          overrides: @config.path_param_overrides.keys
        }
      end

      private

      def candidates_for(endpoint, param, index)
        # An override, and nothing else, for a parameter the seeder configured and could
        # not fill. Inference is exactly what must not happen here: every remaining
        # source would substitute a value belonging to a different mount or a different
        # database, and each of those reads as the endpoint being broken.
        sources = unresolvable_parameter?(param) ? %i[override] : SOURCE_ORDER

        sources.each do |source|
          value = send(:"from_#{source}", endpoint, param, index)
          return [value, source] unless value.nil?
        end

        [nil, nil]
      end

      def unresolvable_parameter?(name) = @unresolvable_parameters.include?(name.to_s)

      def note_lookup(name, endpoint)
        (@looked_up[name] ||= []) << endpoint.to_s
        @looked_up[name].uniq!
      end

      # `/api/v1/posts/{id}/comments` with param :id resolves against the "post"
      # resource — the segment immediately preceding the parameter, singularised.
      # `{post_id}` resolves against "post" directly.
      def from_seeded(endpoint, param, index)
        # BY PARAMETER NAME FIRST, for a resource addressed by a different column per
        # parameter (`factory_map` `values:`). A parameter with no entry falls straight
        # through to its resource's shared value, so this cannot disturb what already
        # works.
        by_parameter = Array(@seeded_ids[param.to_s] || @seeded_ids[param.to_sym])
        unless by_parameter.empty?
          # RECORDED AS ASKED FOR, and it was not. This branch returned before the
          # bookkeeping below, so a `values:` key spelled as the literal parameter name
          # resolved endpoints all run and was then reported by the unconsumed-key audit
          # as having matched nothing -- a warning telling the user to change a key that
          # was working. The audit's remedy was right and its diagnosis was wrong, which
          # is the more dangerous half to get wrong: the user acts on the diagnosis.
          note_lookup(param.to_s, endpoint)
          return by_parameter[index % by_parameter.length]
        end

        resource = resource_for(endpoint, param)
        return nil if resource.nil?

        # WHAT WE LOOKED UNDER, whether or not we found it. A factory_map key is
        # matched against a name derived from the PATH PARAMETER, not from the factory
        # -- `{caller_number}` looks under "caller" -- and a key that does not match is
        # a silent miss: resolution falls through to the recorded literal and the run
        # looks exactly like one with no factory_map entry at all. One integration
        # configured `value:` correctly, watched 100 rows get seeded, saw no warning,
        # and had the recorded literal sent anyway.
        note_lookup(resource, endpoint)

        ids = Array(@seeded_ids[resource] || @seeded_ids[resource.to_sym])
        return nil if ids.empty?

        # Rotated rather than always the first. A single hot row produces
        # unrealistic cache behaviour and can create row-lock contention that does
        # not reflect real traffic.
        ids[index % ids.length]
      end

      def from_recorded(endpoint, param, index)
        recorded = Array(endpoint.recorded_path_values[param])
        return nil if recorded.empty?

        recorded[index % recorded.length]
      end

      def from_override(endpoint, param, _index)
        overrides = @config.path_param_overrides
        by_template = overrides[endpoint.path] || overrides[endpoint.to_s]
        value = by_template.is_a?(Hash) ? (by_template[param] || by_template[param.to_s]) : nil
        # EITHER KEY FORM. A bare-name override was read symbol-only here and both ways
        # for a query parameter, so `"resource_id" => ...` in an initializer worked on
        # one and was silently ignored on the other -- the documented remedy behind a
        # code path that could not reach it, again. It matters more now than it did:
        # for a parameter the seeder configured and could not fill, an override is the
        # ONLY source left.
        value ||= [param, param.to_s].filter_map { |key| overrides[key] unless overrides[key].is_a?(Hash) }.first

        return value unless value.respond_to?(:call)

        # A callable, so an override can look up a slug or a composite key at run
        # time instead of being frozen into the initializer. A raising override is
        # treated as "did not resolve" rather than taking the run down — the
        # endpoint is then reported as unresolved, naming the param.
        begin
          value.call
        rescue StandardError
          nil
        end
      end

      def from_example(endpoint, param, _index)
        endpoint.query_params.find { |q| q[:name].to_s == param.to_s }&.dig(:example)
      end

      # Identifier suffixes an API puts on a path parameter. `_id` alone left
      # `{order_guid}`, `{account_uuid}` and `{author_slug}` unresolvable -- and those
      # are the parameter names used by precisely the APIs that route on a public
      # identifier rather than a primary key.
      ID_SUFFIXES = %w[_id _guid _uuid _slug _code _key _token _number _ref].freeze

      # The suffix half of resource_for, without a path to fall back on. A bare `id` in
      # a query string names no resource and stays unresolved rather than guessing.
      def resource_from_name(name)
        name = name.to_s
        suffix = ID_SUFFIXES.find { |candidate| name.end_with?(candidate) && name != candidate }
        return nil unless suffix

        singularize(name.delete_suffix(suffix))
      end

      def resource_for(endpoint, param)
        name = param.to_s

        # {post_id} -> post, {order_guid} -> order
        resource = resource_from_name(name)
        return resource if resource

        # /posts/{id} -> the segment before the parameter
        segments = endpoint.path.split("/").reject(&:empty?)
        position = segments.index("{#{name}}")
        return nil if position.nil? || position.zero?

        preceding = segments[position - 1]
        return nil if preceding.start_with?("{")

        singularize(preceding)
      end

      # Deliberately naive, and deliberately not ActiveSupport#singularize: that
      # applies the host app's inflections, which is right for the app's own class
      # names and wrong here, where the input is a URL segment. The seeder keys its
      # ids by factory name, and factory_map is the escape hatch when a URL segment
      # and a factory name genuinely diverge.
      def singularize(word)
        case word
        when /ies\z/ then word.sub(/ies\z/, "y")
        when /(ss|sh|ch|x|z)es\z/ then word.sub(/es\z/, "")
        when /s\z/ then word.sub(/s\z/, "")
        else word
        end
      end

      def substitute(template, values)
        values.reduce(template) do |path, (param, value)|
          path.gsub("{#{param}}", value.to_s)
        end
      end
    end
  end
end

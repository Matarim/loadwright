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

      def initialize(config: Loadwright.configuration, seeded_ids: {})
        @config = config
        # { "post" => [1, 2, 3] } — resource name to ids the seeder just created.
        @seeded_ids = seeded_ids
        @cursors = {}
      end

      def seeded_ids=(mapping)
        @seeded_ids = mapping
        @cursors = {}
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
      def resolve_query_param(name, index: 0)
        resource = resource_from_name(name)
        return nil if resource.nil?

        ids = Array(@seeded_ids[resource] || @seeded_ids[resource.to_sym])
        return nil if ids.empty?

        ids[index % ids.length]
      end

      # True for `widget_id`, `account_guid`, `order_ref`. False for `view`, `page`,
      # `q` -- an ordinary filter is not an identifier and replaying it is exactly
      # right.
      def identifier_shaped?(name)
        !resource_from_name(name).nil?
      end

      def to_h
        {
          seeded_resources: @seeded_ids.keys,
          overrides: @config.path_param_overrides.keys
        }
      end

      private

      def candidates_for(endpoint, param, index)
        SOURCE_ORDER.each do |source|
          value = send(:"from_#{source}", endpoint, param, index)
          return [value, source] unless value.nil?
        end

        [nil, nil]
      end

      # `/api/v1/posts/{id}/comments` with param :id resolves against the "post"
      # resource — the segment immediately preceding the parameter, singularised.
      # `{post_id}` resolves against "post" directly.
      def from_seeded(endpoint, param, index)
        resource = resource_for(endpoint, param)
        return nil if resource.nil?

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
        value ||= overrides[param] if overrides[param] && !overrides[param].is_a?(Hash)

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

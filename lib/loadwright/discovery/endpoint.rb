# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Discovery
    # The normalised representation every discovery source produces.
    #
    # Keyed by (path_template, verb) — NOT by concrete path. That is the merge key
    # for a reason: the OpenAPI document says `/api/v1/posts/{id}/comments`, while
    # integration-spec recording observes `/api/v1/posts/42/comments`. Without
    # reverse-mapping the recorded path back to its template, the two sources never
    # merge and the same endpoint appears twice with half the information each.
    class Endpoint
      SAFE_VERBS = %i[get head options].freeze
      SOURCES = %i[openapi integration_spec route graphql].freeze

      attr_reader :path, :verb, :sources, :operation_id, :path_params, :query_params,
                  :request_body, :request_schema, :response_schemas, :recorded_path_values,
                  :recorded_headers, :expected_statuses, :description, :graphql_operation,
                  :recorded_success, :recorded_attempts,
                  :graphql_operation_type, :graphql_page_size_variable

      def initialize(path:, verb:, source: nil, sources: nil, operation_id: nil,
                     path_params: nil, query_params: [], request_body: nil,
                     request_schema: nil, response_schemas: {}, recorded_path_values: {},
                     recorded_headers: {}, expected_statuses: [], description: nil, graphql_operation: nil,
                     recorded_success: nil, recorded_attempts: nil,
                     graphql_operation_type: :query, graphql_page_size_variable: nil)
        @path = path
        @verb = verb.to_s.downcase.to_sym
        @sources = Array(sources || source).compact.map(&:to_sym)
        validate_sources!

        # GRAPHQL PUTS EVERY OPERATION BEHIND ONE PATH AND VERB, so (path, verb) --
        # which identifies a REST endpoint perfectly well -- collapses an entire API
        # into a single row. The operation name is the identity there, and it is
        # carried separately rather than folded into `path` so that nothing which
        # reasons about paths (excluded_paths, path params, the resource name) starts
        # seeing an operation name where it expects a URL.
        @graphql_operation = graphql_operation
        @graphql_operation_type = graphql_operation_type&.to_sym
        @graphql_page_size_variable = graphql_page_size_variable
        @operation_id = operation_id
        # THE TEMPLATE IS AUTHORITATIVE, and a declared list may only ADD to it.
        # `path_params || params_in(path)` let an explicitly EMPTY list win -- which
        # is what a recording with no captured values produces -- so an endpoint whose
        # path plainly reads `/posts/{id}` claimed to have no parameters, resolution
        # early-returned, and the raw template went out as a URL.
        @path_params = (Array(path_params).map(&:to_sym) | self.class.params_in(path).map(&:to_sym))
        @query_params = query_params.freeze
        @request_body = request_body
        @request_schema = request_schema
        @response_schemas = response_schemas.freeze
        @recorded_path_values = recorded_path_values.freeze
        # What a real, passing request to this endpoint sent. Replayed selectively --
        # see config.replay_recorded_headers -- because the point is content
        # negotiation, not resending somebody's Host header.
        @recorded_headers = recorded_headers.freeze
        @expected_statuses = expected_statuses.freeze
        # nil when no recording contributed; true/false once one did.
        @recorded_success = recorded_success
        @recorded_attempts = recorded_attempts
        @description = description
        freeze
      end

      # Both `{id}` (OpenAPI) and `:id` (Rails) forms, so a route-sourced endpoint
      # and a doc-sourced one agree on the parameter list.
      def self.params_in(path)
        path.to_s.scan(/\{([^}]+)\}|:([A-Za-z_][A-Za-z0-9_]*)/).map { |braced, colon| braced || colon }
      end

      # Rails route templates are normalised to the OpenAPI form on the way in, so
      # the merge key is one shape rather than two.
      #
      # The `(.:format)` suffix is stripped BEFORE `:param` conversion, or the
      # colon inside it becomes `{format}` and every route ends up with a phantom
      # path parameter — which then fails resolution and marks the endpoint
      # unresolved for a segment that is not really there.
      def self.normalize_path(path)
        path.to_s
            .sub(/\(\.:format\)\z/, "")
            .gsub(/:([A-Za-z_][A-Za-z0-9_]*)/) { "{#{Regexp.last_match(1)}}" }
      end

      def key = [path, verb, graphql_operation].compact

      # THE KEY A DOCUMENT AND A ROUTE CAN ACTUALLY AGREE ON.
      #
      # A document writes `/parents/{parent_guid}` where the app's route says
      # `/parents/{parent_id}`. Same endpoint, same segments, one route -- and keyed by
      # the raw path they are two, so the document's schema never reaches the endpoint
      # that was measured. Parameter NAMES are documentation; the segment structure is
      # the route.
      #
      # Safe because a path template's parameter name cannot distinguish two routes:
      # within one source, two templates differing only in parameter spelling ARE the
      # same route. Across sources, they are the same route described twice.
      def structural_key = [self.class.structural_path(path), verb, graphql_operation].compact

      def self.structural_path(path) = path.to_s.gsub(/\{[^}]*\}/, "{}")

      def graphql? = !graphql_operation.nil?

      # Recorded, and never once successfully. The template is real -- a route
      # recognised it -- but every capture of it was a spec asserting a rejection, so no
      # usable identifier was ever taken from it.
      def recorded_only_as_rejection?
        recorded_success == false && recorded_attempts.to_i.positive?
      end

      # REST varies page size with a query parameter, which any endpoint will accept
      # (and ignoring it shows up as "unable to vary result size"). GraphQL varies it
      # through a declared variable, so an operation without one cannot be swept at
      # all -- and saying so beats measuring the same page three times and calling the
      # flat line healthy.
      def page_size_varying? = !graphql? || !graphql_page_size_variable.nil?

      # THE SWEEP ASKS THE ENDPOINT WHAT IT ACCEPTS, where the document says so.
      #
      # A page size the sweep chose that the endpoint rejects is our doing, not theirs
      # -- 0.0.7 added a whole outcome reason to say so. The better answer is not to
      # choose it: an enum on the page-size parameter names the legal values exactly,
      # and reading it turns a fabricated inconsistency into a real measurement.
      #
      # nil when nothing is declared, so the configured sweep stays the default.
      def declared_page_sizes(parameter_names)
        wanted = Array(parameter_names).map(&:to_s)
        param = Array(query_params).find do |candidate|
          wanted.include?(candidate[:name].to_s) && Array(candidate[:enum]).any?
        end
        return nil if param.nil?

        values = Array(param[:enum]).filter_map { |v| Integer(v, exception: false) }.sort
        values.empty? ? nil : values
      end

      def page_size_unavailable_reason
        return nil if page_size_varying?

        "#{graphql_operation} declares no page-size variable, so its result size cannot be " \
          "varied. Parameterise the connection argument (`$first: Int!`) to make the " \
          "returned-record slope available for this operation."
      end

      # The body to send for a given page size. Only GraphQL uses it: REST carries
      # page size in the query string.
      def body_for(page_size)
        return request_body unless graphql? && graphql_page_size_variable && page_size

        body = (request_body || {}).dup
        body["variables"] = (body["variables"] || {}).merge(graphql_page_size_variable => page_size)
        body
      end

      # The resource this endpoint is about, from the last static path segment.
      # `/api/v1/posts` and `/api/v1/posts/{id}` are both "post".
      #
      # Used to ask the seeder how many rows exist FOR THIS ENDPOINT. Passing a global
      # seeded count instead produces a specific false positive: an endpoint whose
      # resource was never in factory_map returns an empty collection quite correctly,
      # and gets reported as "data was seeded but nothing came back — your scope is
      # wrong". A false positive of that shape is worse than no signal, because the
      # developer goes looking for a scoping bug that does not exist.
      def resource_name
        segment = path.split("/").reject { |part| part.empty? || part.start_with?("{") }.last
        return nil if segment.nil?

        singularize(segment)
      end

      def to_s
        return "#{verb.to_s.upcase} #{path} (#{graphql_operation})" if graphql?

        "#{verb.to_s.upcase} #{path}"
      end

      # THE HTTP VERB IS NOT THE ANSWER FOR GRAPHQL. Every operation is a POST,
      # including the reads -- so verb-based classification marks an entire GraphQL
      # API as mutating, and `allow_mutating_requests` (a safety opt-in that exists
      # for endpoints that WRITE) becomes a prerequisite for measuring queries that
      # only read. That is both useless and a misuse of the gate: it teaches people
      # to switch on write traffic in order to test reads.
      #
      # The operation type is the answer. A `mutation` mutates; a `query` does not.
      def mutating?
        return graphql_operation_type == :mutation if graphql?

        !SAFE_VERBS.include?(verb)
      end

      def from?(source) = sources.include?(source)

      def path_params? = !path_params.empty?

      # Whether a request can actually be built. An endpoint discovered from routes
      # alone with a body-requiring verb has no example, and
      # discovery-and-load-engine.md is explicit that those are reported as
      # "discovered but no example available; skipped" rather than guessed at.
      def example_available?
        return true unless mutating?

        !request_body.nil? || from?(:integration_spec)
      end

      # The schema for the success response, used by the validity gate. Picks the
      # declared 2xx; a doc that declares only errors gets nil, not a guess.
      def success_response_schema
        response_schemas.find { |status, _| status.to_s.start_with?("2") }&.last
      end

      def success_status
        expected_statuses.find { |status| (200..299).cover?(status) } ||
          (mutating? ? 201 : 200)
      end

      # Merges another source's endpoint for the same key. Integration-spec data
      # wins on request shape (proven-valid, and often richer than a doc that has
      # drifted); OpenAPI wins on schemas, which recording cannot produce.
      def merge(other)
        unless other.structural_key == structural_key
          raise ArgumentError, "cannot merge #{other.key.inspect} into #{key.inspect}"
        end

        recorded = other.from?(:integration_spec) ? other : self
        documented = other.from?(:openapi) ? other : self
        winner = authoritative_path_source(other)

        self.class.new(
          path: winner.path,
          verb: verb,
          sources: (sources | other.sources),
          operation_id: operation_id || other.operation_id,
          # WHEN THE SPELLINGS DIFFER, ONLY THE WINNING TEMPLATE'S NAMES SURVIVE.
          # Unioning them would leave the endpoint claiming a parameter its own path
          # does not contain, which resolution then tries and fails to fill -- turning
          # a successful join into an unresolved-parameter skip. Identical paths keep
          # the union unchanged, which is every case but this one.
          path_params: winner.path == other.path && winner.path == path ? (path_params | other.path_params) : winner.path_params,
          query_params: recorded.query_params.empty? ? documented.query_params : recorded.query_params,
          request_body: recorded.request_body || documented.request_body,
          request_schema: documented.request_schema || recorded.request_schema,
          response_schemas: documented.response_schemas.merge(recorded.response_schemas) { |_, a, b| a || b },
          recorded_path_values: deep_merge_recorded(other),
          recorded_headers: documented.recorded_headers.merge(recorded.recorded_headers),
          expected_statuses: (expected_statuses | other.expected_statuses),
          recorded_success: [recorded_success, other.recorded_success].compact.any? || nil,
          recorded_attempts: [recorded_attempts, other.recorded_attempts].compact.max,
          description: description || other.description
        )
      end

      def to_h
        {
          path: path,
          verb: verb,
          sources: sources,
          operation_id: operation_id,
          path_params: path_params,
          mutating: mutating?,
          example_available: example_available?,
          has_response_schema: !success_response_schema.nil?,
          recorded_path_values: recorded_path_values
        }
      end

      private

      # WHOSE SPELLING OF THE TEMPLATE GETS REQUESTED. The application's own, always:
      # a route is what the app serves, a recording is a path it actually answered, and
      # a document is a description that may have drifted. Requesting the document's
      # spelling of a parameter is harmless in itself -- the name inside the braces is
      # never sent -- but it makes the report name a template the app does not have.
      PATH_AUTHORITY = %i[route integration_spec openapi graphql].freeze

      def authoritative_path_source(other)
        return self if path == other.path

        mine = PATH_AUTHORITY.index { |source| from?(source) } || PATH_AUTHORITY.length
        theirs = PATH_AUTHORITY.index { |source| other.from?(source) } || PATH_AUTHORITY.length

        theirs < mine ? other : self
      end

      def deep_merge_recorded(other)
        (recorded_path_values.keys | other.recorded_path_values.keys).to_h do |param|
          [param, (Array(recorded_path_values[param]) | Array(other.recorded_path_values[param]))]
        end
      end

      # Deliberately naive, and deliberately not ActiveSupport#singularize: that applies
      # the host app's inflections, which are right for its class names and wrong for a
      # URL segment. PathParamResolver uses the same rule, and factory_map is the escape
      # hatch when a URL segment and a factory name genuinely diverge.
      def singularize(word)
        case word
        when /ies\z/ then word.sub(/ies\z/, "y")
        when /(ss|sh|ch|x|z)es\z/ then word.sub(/es\z/, "")
        when /s\z/ then word.sub(/s\z/, "")
        else word
        end
      end

      def validate_sources!
        unknown = sources - SOURCES
        raise ArgumentError, "unknown endpoint source(s): #{unknown.join(', ')}" if unknown.any?
        raise ArgumentError, "an endpoint must record where it came from" if sources.empty?
      end
    end
  end
end

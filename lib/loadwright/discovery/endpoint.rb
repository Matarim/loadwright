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
      SOURCES = %i[openapi integration_spec route].freeze

      attr_reader :path, :verb, :sources, :operation_id, :path_params, :query_params,
                  :request_body, :request_schema, :response_schemas, :recorded_path_values,
                  :expected_statuses, :description

      def initialize(path:, verb:, source: nil, sources: nil, operation_id: nil,
                     path_params: nil, query_params: [], request_body: nil,
                     request_schema: nil, response_schemas: {}, recorded_path_values: {},
                     expected_statuses: [], description: nil)
        @path = path
        @verb = verb.to_s.downcase.to_sym
        @sources = Array(sources || source).compact.map(&:to_sym)
        validate_sources!

        @operation_id = operation_id
        # Derived from the template when not stated, because a route-discovered
        # endpoint has no parameter list but its path still names its params.
        @path_params = (path_params || self.class.params_in(path)).map(&:to_sym)
        @query_params = query_params.freeze
        @request_body = request_body
        @request_schema = request_schema
        @response_schemas = response_schemas.freeze
        @recorded_path_values = recorded_path_values.freeze
        @expected_statuses = expected_statuses.freeze
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

      def key = [path, verb]

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

      def to_s = "#{verb.to_s.upcase} #{path}"

      def mutating? = !SAFE_VERBS.include?(verb)

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
        raise ArgumentError, "cannot merge #{other.key.inspect} into #{key.inspect}" unless other.key == key

        recorded = other.from?(:integration_spec) ? other : self
        documented = other.from?(:openapi) ? other : self

        self.class.new(
          path: path,
          verb: verb,
          sources: (sources | other.sources),
          operation_id: operation_id || other.operation_id,
          path_params: (path_params | other.path_params),
          query_params: recorded.query_params.empty? ? documented.query_params : recorded.query_params,
          request_body: recorded.request_body || documented.request_body,
          request_schema: documented.request_schema || recorded.request_schema,
          response_schemas: documented.response_schemas.merge(recorded.response_schemas) { |_, a, b| a || b },
          recorded_path_values: deep_merge_recorded(other),
          expected_statuses: (expected_statuses | other.expected_statuses),
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

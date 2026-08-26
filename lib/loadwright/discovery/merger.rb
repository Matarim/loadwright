# frozen_string_literal: true

require "loadwright/discovery/endpoint"
require "loadwright/endpoint_outcome"

module Loadwright
  module Discovery
    # Merges the three sources into one endpoint list, keyed by
    # (path_template, verb), and decides what is exercised.
    #
    # WHAT IS EXCLUDED IS RECORDED, NOT DROPPED. Every skip comes back as an
    # EndpointOutcome with a reason, because "this endpoint is not in the report"
    # and "this endpoint was not tested and here is why" look identical to a reader
    # otherwise — and the first reads as coverage the run did not have. That is the
    # same failure the whole three-state outcome model exists to prevent, applied to
    # discovery rather than to measurement.
    class Merger
      Result = Struct.new(:endpoints, :skipped, :warnings, keyword_init: true) do
        def to_h
          {
            endpoint_count: endpoints.length,
            skipped_count: skipped.length,
            by_source: endpoints.flat_map(&:sources).tally,
            skipped: skipped.map { |outcome| { endpoint: outcome.endpoint.to_s, reason: outcome.reason } },
            warnings: warnings
          }
        end
      end

      def initialize(config: Loadwright.configuration)
        @config = config
      end

      # `sources` is a Hash of source name => Array(Endpoint), so the caller decides
      # which sources ran and the merge does not have to know how to build any of
      # them.
      def merge(openapi: [], integration_spec: [], route: [], graphql: [], warnings: [])
        merged = {}

        # Order matters only for which source's data seeds the key; Endpoint#merge
        # resolves precedence per field regardless of arrival order.
        [openapi, integration_spec, route, graphql].each do |group|
          group.each do |endpoint|
            existing = merged[endpoint.key]
            merged[endpoint.key] = existing ? existing.merge(endpoint) : endpoint
          end
        end

        partition(merged.values, warnings)
      end

      private

      def partition(endpoints, warnings)
        kept = []
        skipped = []

        endpoints.each do |endpoint|
          # Out of scope is dropped, not reported. An endpoint the user excluded is
          # not an inconclusive result — listing it as one would make excluded_paths
          # look like a source of failures. Checked BEFORE classification, because a
          # nil skip reason means "keep it".
          next if out_of_scope?(endpoint)

          reason = skip_reason(endpoint)

          if reason
            skipped << EndpointOutcome.inconclusive(
              endpoint: endpoint, reason: reason[0], detail: reason[1]
            )
          else
            kept << endpoint
          end
        end

        Result.new(
          endpoints: kept.sort_by { |endpoint| [endpoint.path, endpoint.verb.to_s] },
          skipped: skipped,
          warnings: warnings
        )
      end

      # Returns [reason_symbol, detail], or nil to keep the endpoint. Scope filtering
      # happens before this is called.
      def skip_reason(endpoint)
        if endpoint.mutating? && !@config.allow_mutating_requests
          return [:no_example_available,
                  "mutating verb (#{endpoint.verb.to_s.upcase}) and allow_mutating_requests is false"]
        end

        unless endpoint.example_available?
          return [:no_example_available,
                  "discovered from #{endpoint.sources.join(', ')} with no usable example request; " \
                  "add it to the OpenAPI document or record a request spec that exercises it"]
        end

        nil
      end

      def out_of_scope?(endpoint)
        included = @config.included_paths
        return true if included && !Array(included).any? { |pattern| endpoint.path.match?(pattern) }

        Array(@config.excluded_paths).any? { |pattern| endpoint.path.match?(pattern) }
      end

      public

      # Exposed so the CLI's --only flag and the dry-run listing share one filter
      # implementation with the merge, rather than two that can disagree.
      def self.matches_only?(endpoint, pattern)
        return true if pattern.nil?

        endpoint.path.include?(pattern.to_s) || endpoint.to_s.match?(Regexp.new(pattern.to_s))
      rescue RegexpError
        endpoint.path.include?(pattern.to_s)
      end
    end
  end
end

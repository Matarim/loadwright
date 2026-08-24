# frozen_string_literal: true

require "loadwright/discovery/openapi_source"
require "loadwright/discovery/integration_spec_source"
require "loadwright/discovery/route_source"
require "loadwright/discovery/merger"

module Loadwright
  module Discovery
    # Runs the three sources and merges them. This is the whole discovery phase as a
    # single call, so `loadwright run` and `loadwright run --dry-run` cannot end up
    # discovering different endpoint sets -- the dry run's entire purpose is to show
    # the user what the real run will do, which it can only do if it is the same code.
    #
    # A source that is configured off contributes nothing; a source the user
    # EXPLICITLY POINTED SOMEWHERE that finds nothing contributes a WARNING. The two
    # look identical in the endpoint list and are completely different problems: the
    # first is what the user asked for, the second is usually a wrong path in the
    # initializer. discovery-and-load-engine.md's "fail loud" rule applies to finding
    # nothing, not just to parse errors.
    #
    # The warnings key off `explicitly_set?` rather than off the value, because both
    # path settings have LAZY DEFAULTS pointing at conventional locations. Warning on
    # the value made every app without a swagger/ directory print two warnings about
    # sources it had never asked for -- which is how a warning channel stops being
    # read at all.
    class Pipeline
      Result = Struct.new(:endpoints, :skipped, :warnings, :by_source, keyword_init: true)

      def initialize(config: Loadwright.configuration, stdout: $stdout)
        @config = config
        @stdout = stdout
      end

      def discover(only: nil)
        warnings = []

        openapi = from_openapi(warnings)
        recorded = from_integration_specs(warnings)
        routes = from_routes(warnings)

        merged = Merger.new(config: @config).merge(
          openapi: openapi, integration_spec: recorded, route: routes, warnings: warnings
        )

        endpoints = merged.endpoints.select { |e| Merger.matches_only?(e, only) }
        warnings << only_matched_nothing_message(only, merged.endpoints) if only && endpoints.empty?

        Result.new(
          endpoints: endpoints,
          # Filtering the skip list too, so `--only` narrows the whole report rather
          # than leaving unrelated endpoints in its "not tested" section.
          skipped: merged.skipped.select { |outcome| Merger.matches_only?(outcome.endpoint, only) },
          warnings: merged.warnings,
          by_source: { openapi: openapi.length, integration_spec: recorded.length, route: routes.length }
        )
      end

      private

      def from_openapi(warnings)
        paths = Array(@config.openapi_spec_paths).compact
        return [] if paths.empty?

        source = OpenapiSource.new(config: @config, stdout: @stdout)
        endpoints = source.endpoints
        warnings.concat(source.warnings)
        if endpoints.empty? && @config.explicitly_set?(:openapi_spec_paths)
          warnings << "openapi_spec_paths points at #{paths.join(', ')} but no endpoints were parsed from it"
        end
        endpoints
      end

      # Reads the file a previous `loadwright record` wrote. It never runs the specs
      # itself -- recording is a separate command precisely because running someone's
      # suite is not something a load-test run should do as a side effect.
      def from_integration_specs(warnings)
        source = IntegrationSpecSource.new(config: @config, stdout: @stdout)
        path = source.default_output_path
        unless File.exist?(path)
          warnings << recording_absent_message(path) if @config.explicitly_set?(:integration_spec_paths)
          return []
        end

        endpoints = source.endpoints(input_path: path)
        warnings.concat(source.warnings)
        endpoints
      end

      def from_routes(warnings)
        return [] unless @config.route_discovery

        endpoints = RouteSource.new(config: @config).endpoints
        warnings << "route_discovery is on but the application exposes no matching routes" if endpoints.empty?
        endpoints
      rescue StandardError => e
        # Route introspection touches the host's router, which can raise for reasons
        # that have nothing to do with the rest of the run. Losing the gap-filling
        # source is survivable; losing the run is not.
        warnings << "route discovery failed (#{e.class}: #{e.message}); continuing without it"
        []
      end

      def recording_absent_message(path)
        "integration_spec_paths is set but no recording exists at #{path}. Run " \
          "`bundle exec loadwright record --specs #{Array(@config.integration_spec_paths).first}` " \
          "first, or this source contributes nothing."
      end

      def only_matched_nothing_message(only, endpoints)
        "--only #{only.inspect} matched none of the #{endpoints.length} discovered endpoint(s); " \
          "nothing will be exercised"
      end
    end
  end
end

# frozen_string_literal: true

require "json"
require "yaml"
require "loadwright/errors"
require "loadwright/discovery/endpoint"
require "loadwright/discovery/schema_ref"

module Loadwright
  module Discovery
    # Endpoints from an OpenAPI/Swagger document.
    #
    # FAIL LOUD ON A PARTIAL PARSE. This is the rule that shapes the whole class. A
    # document that parses only halfway must not yield the endpoints it managed to
    # read, because an endpoint that was never tested gets reported as ABSENT
    # rather than SKIPPED — and a report listing eight clean endpoints out of a
    # sixteen-endpoint API tells the developer their API is clean when half of it
    # was never looked at. So: validate the whole document first, and raise
    # DiscoveryError naming every problem.
    #
    # THE OPENAPI 3.1 SITUATION, verified against openapi3_parser 0.10.1 rather
    # than assumed:
    #
    #   * A `openapi: 3.1.0` document with only 3.0-compatible content parses fine.
    #     The version string alone is not rejected.
    #   * 3.1-only constructs are NOT supported: `webhooks` at the root, type arrays
    #     (`type: [string, "null"]`), and numeric `exclusiveMaximum`/`exclusiveMinimum`
    #     all produce validation errors.
    #   * Worse for our purposes, `document.paths` RAISES on such a document rather
    #     than returning what it could read.
    #
    # That last point is convenient — accidental partial discovery is hard — but it
    # is not something to rely on, so the explicit `valid?` gate runs first and the
    # error message names 3.1 as the likely cause when the document declares it.
    #
    # WHY TWO REPRESENTATIONS OF THE SAME DOCUMENT. openapi3_parser validates;
    # the raw parsed hash carries the schemas. SKILL.md says not to hand-roll
    # YAML/JSON schema walking, and this honours that — the parser is the authority
    # on whether the document is well-formed. But its `Node::Schema#to_h` is
    # shallow and injects OpenAPI defaults including `additionalProperties: false`,
    # so validating a real response against it would reject any payload carrying a
    # field the document did not enumerate. See SchemaRef.
    class OpenapiSource
      # Rails-style path params are `:id`; OpenAPI's are `{id}`. Documents are
      # already in the second form, so nothing to convert here — but the constant
      # is named so the merge key's shape is discoverable from either side.
      PATH_PARAM = /\{([^}]+)\}/

      HTTP_VERBS = %w[get put post delete options head patch trace].freeze

      attr_reader :warnings

      def initialize(config: Loadwright.configuration, stdout: $stdout)
        @config = config
        @stdout = stdout
        @warnings = []
      end

      # Returns an Array of Endpoint, or raises DiscoveryError. Never returns a
      # partial list.
      def endpoints
        paths = Array(@config.openapi_spec_paths).map(&:to_s)
        return [] if paths.empty?

        paths.flat_map { |path| endpoints_in(path) }
      end

      private

      def endpoints_in(path)
        unless File.file?(path)
          # Provenance decides whether a missing file is an error. The default value
          # points at the rswag convention, which most apps do not have — refusing
          # to run over that would make the tool unusable out of the box. But a path
          # the USER wrote is a statement that the file is there, and silently
          # skipping it is how someone ends up reading a report of four endpoints
          # believing it covers forty.
          if @config.explicitly_set?(:openapi_spec_paths)
            raise DiscoveryError,
                  "openapi_spec_paths names #{path}, which does not exist. Loadwright will not run a " \
                  "partial discovery: an endpoint that was never tested would be reported as absent " \
                  "rather than skipped. Fix the path, or remove it from the list."
          end

          @warnings << "no OpenAPI document at the default location #{path}; skipping OpenAPI discovery"
          return []
        end

        raw = load_raw(path)
        validate!(path, raw)
        build_endpoints(raw)
      end

      def load_raw(path)
        content = File.read(path)
        parsed = path.end_with?(".json") ? JSON.parse(content) : YAML.safe_load(content, aliases: true)
        raise DiscoveryError, "#{path} did not parse to an object" unless parsed.is_a?(Hash)

        parsed
      rescue Psych::SyntaxError, JSON::ParserError => e
        raise DiscoveryError, "#{path} is not valid YAML/JSON: #{e.message}"
      end

      def validate!(path, raw)
        require "openapi3_parser"

        document = Openapi3Parser.load_file(path)
        return if document.valid?

        errors = document.errors.to_a.map { |e| describe_error(e) }
        raise DiscoveryError, parse_failure_message(path, raw, errors, write_error_report(path, raw, errors))
      rescue Openapi3Parser::Error => e
        # The parser raises rather than reporting for some malformed documents,
        # which is the same outcome by a different route.
        raise DiscoveryError,
              parse_failure_message(path, raw, [e.message], write_error_report(path, raw, [e.message]))
      end

      # WITH THE LOCATION, not just the message. `Validation::Error#to_s` returns only
      # the message, so a whole document's worth of problems came back as
      # "Invalid type. Expected String" with nothing to point at — which in a
      # four-hundred-line document is close to useless, and makes a loud failure
      # undiagnosable. The context is a JSON pointer, unescaped here so it reads as the
      # path the author actually wrote.
      def describe_error(error)
        location = error.context.to_s if error.respond_to?(:context)
        return error.message if location.nil? || location.empty?

        "#{error.message} — at #{location.gsub('~1', '/').gsub('~0', '~')}"
      end

      # The full list on disk, and a count of how much of the document is affected.
      # The refusal itself is right, but 20 truncated errors with no way to see the
      # rest turns a fixable problem into a wall -- nobody can fix 52 errors they
      # cannot read, and "31 of 44 paths" is the difference between a morning's work
      # and abandoning the tool.
      def write_error_report(path, raw, errors)
        require "fileutils"
        require "json"

        out = File.join(@config.report_output_dir.to_s, "openapi-errors.json")
        FileUtils.mkdir_p(File.dirname(out))
        File.write(out, JSON.pretty_generate(
                          "document" => path.to_s, "error_count" => errors.length,
                          "paths_total" => Array(raw["paths"]&.keys).length,
                          "paths_affected" => affected_paths(errors).length,
                          "affected_paths" => affected_paths(errors),
                          "errors" => errors
                        ))
        out
      rescue StandardError
        # Never let the diagnostic replace the diagnosis.
        nil
      end

      # From the JSON pointer: `#/paths//api/v2/x/post/...` -> `/api/v2/x`.
      def affected_paths(errors)
        errors.filter_map { |error| error[%r{ at #/paths/(/[^/]*(?:/[^/]+)*?)(?:/(?:get|put|post|delete|patch|head|options|trace)\b|\z)}, 1] }
              .uniq.sort
      end

      def parse_failure_message(path, raw, errors, report_path = nil)
        listed = errors.first(20).map { |error| "  - #{error}" }.join("\n")
        affected = affected_paths(errors)
        total = Array(raw["paths"]&.keys).length

        more = if errors.length > 20
                 "\n  ...and #{errors.length - 20} more"
               else
                 ""
               end

        scope = if total.positive? && affected.any?
                  "\n#{errors.length} error(s) across #{affected.length} of #{total} path(s); " \
                    "#{total - affected.length} path(s) parsed cleanly."
                else
                  ""
                end

        written = report_path ? "\nThe full list is in #{report_path}." : ""

        message = <<~MSG
          #{path} could not be fully parsed as an OpenAPI document:

          #{listed}#{more}
          #{scope}#{written}

          Loadwright refuses to discover endpoints from a document it could not read completely. A
          partial endpoint list is worse than none: the endpoints it missed would be reported as
          absent rather than skipped, and you would read a clean report covering half your API.

          While you fix it, integration-spec recording and route discovery both work without an
          OpenAPI document -- unset openapi_spec_paths and run `loadwright record`.
        MSG

        message += <<~MSG if raw["openapi"].to_s.start_with?("3.1")

          This document declares OpenAPI #{raw['openapi']}. Loadwright's parser (openapi3_parser)
          targets 3.0: it accepts a 3.1 version string, but rejects 3.1-only constructs — `webhooks`
          at the document root, type arrays such as `type: [string, "null"]`, and numeric
          `exclusiveMaximum`/`exclusiveMinimum`. The errors above are the likely places. Options:
          express those parts in 3.0-compatible form, or rely on integration-spec recording and
          route discovery for this API instead.
        MSG

        message
      end

      def build_endpoints(raw)
        Array(raw["paths"]).flat_map do |template, path_item|
          next [] unless path_item.is_a?(Hash)

          shared_params = Array(path_item["parameters"])

          path_item.filter_map do |verb, operation|
            next unless HTTP_VERBS.include?(verb.to_s.downcase)
            next unless operation.is_a?(Hash)

            build_endpoint(raw, template, verb, operation, shared_params)
          end
        end
      end

      def build_endpoint(raw, template, verb, operation, shared_params)
        parameters = shared_params + Array(operation["parameters"])
        pointer = "#/paths/#{escape(template)}/#{verb}"

        Endpoint.new(
          path: template,
          verb: verb,
          source: :openapi,
          operation_id: operation["operationId"],
          description: operation["summary"] || operation["description"],
          path_params: parameters.select { |p| p["in"] == "path" }.map { |p| p["name"] } |
                       template.scan(PATH_PARAM).flatten,
          query_params: query_params(parameters),
          request_body: request_example(operation),
          request_schema: request_schema(raw, pointer, operation),
          response_schemas: response_schemas(raw, pointer, operation),
          expected_statuses: Array(operation["responses"]&.keys).filter_map { |s| Integer(s, exception: false) }
        )
      end

      def query_params(parameters)
        parameters.select { |p| p["in"] == "query" }.map do |param|
          {
            name: param["name"],
            required: param["required"] == true,
            example: param["example"] || param.dig("schema", "example") || param.dig("schema", "default"),
            type: param.dig("schema", "type")
          }
        end
      end

      # A real example from the document is always preferred; a synthetic one built
      # from the schema is a fallback, not the primary path. A doc's own example has
      # been written by someone who knows what the endpoint accepts.
      def request_example(operation)
        content = operation.dig("requestBody", "content")
        return nil unless content.is_a?(Hash)

        json = content["application/json"] || content.values.first
        return nil unless json.is_a?(Hash)

        json["example"] ||
          json.dig("examples")&.values&.first&.dig("value") ||
          synthesize(json["schema"])
      end

      # Type-appropriate placeholders, one level deep. Deliberately shallow: a
      # deeply-synthesised body is a guess dressed up as data, and an endpoint whose
      # body cannot be built honestly is better reported as
      # "no usable example available" than exercised with invented values.
      def synthesize(schema, depth: 0)
        return nil unless schema.is_a?(Hash) && depth < 3

        case schema["type"]
        when "object", nil
          properties = schema["properties"]
          return nil unless properties.is_a?(Hash)

          required = Array(schema["required"])
          keys = required.any? ? required : properties.keys
          keys.to_h { |key| [key, synthesize(properties[key], depth: depth + 1)] }
        when "array" then [synthesize(schema["items"], depth: depth + 1)].compact
        when "string" then schema["example"] || schema["default"] || (schema["enum"]&.first) || "loadwright"
        when "integer" then schema["example"] || schema["default"] || 1
        when "number" then schema["example"] || schema["default"] || 1.0
        when "boolean" then schema.fetch("example", schema.fetch("default", true))
        end
      end

      def request_schema(raw, pointer, operation)
        content = operation.dig("requestBody", "content")
        return nil unless content.is_a?(Hash)

        media_type = content.key?("application/json") ? "application/json" : content.keys.first
        return nil if media_type.nil?

        SchemaRef.for(
          document: raw,
          pointer: "#{pointer}/requestBody/content/#{escape(media_type)}/schema"
        )
      end

      def response_schemas(raw, pointer, operation)
        Array(operation["responses"]).each_with_object({}) do |(status, response), out|
          next unless response.is_a?(Hash)

          content = response["content"]
          next unless content.is_a?(Hash)

          media_type = content.key?("application/json") ? "application/json" : content.keys.first
          next if media_type.nil?

          out[status.to_s] = SchemaRef.for(
            document: raw,
            pointer: "#{pointer}/responses/#{escape(status)}/content/#{escape(media_type)}/schema"
          )
        end
      end

      # JSON Pointer escaping (RFC 6901). `~` first, or the `/` replacement's tildes
      # get double-escaped.
      def escape(segment) = segment.to_s.gsub("~", "~0").gsub("/", "~1")
    end
  end
end

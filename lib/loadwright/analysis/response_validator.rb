# frozen_string_literal: true

require "json"
require "loadwright/endpoint_outcome"
require "loadwright/measurement"

module Loadwright
  module Analysis
    # THE VALIDITY GATE. Runs before any performance signal is computed.
    #
    # THE FAILURE THIS PREVENTS, stated plainly because everything here follows from
    # it: an endpoint that returns 403 in 4ms with 1 query looks, to a purely
    # query-counting tool, like the healthiest endpoint in the entire API. It ranks
    # top of the "clean" list. An endpoint returning [] because the seeded records
    # missed its scope looks identical to one that is genuinely well-optimised.
    # Reporting either as clean is WORSE than reporting nothing, because the
    # developer now believes something false about their app.
    #
    # So: no endpoint may be reported as healthy unless its response proves it
    # actually did the work.
    #
    # Every failure produces `inconclusive` WITH A SPECIFIC REASON, not a generic
    # one, because the reasons map to different actions: fix auth, fix the factory
    # trait, update the OpenAPI document, exclude the path.
    class ResponseValidator
      # Keys real APIs wrap collections in. Checked in order; the first array found
      # wins. Not exhaustive by design — an unrecognised envelope makes the record
      # count unavailable, which is honest, rather than guessing at zero.
      ENVELOPE_KEYS = %w[data results items records rows entries collection].freeze

      Verdict = Struct.new(:valid, :reason, :detail, :record_count, :body_bytes, :shape,
                           :schema_errors, keyword_init: true) do
        def valid? = valid == true

        def collection? = !record_count.nil?

        def to_h
          {
            valid: valid, reason: reason, detail: detail, record_count: record_count,
            body_bytes: body_bytes, shape: shape, schema_errors: schema_errors
          }.compact
        end
      end

      def initialize(config: Loadwright.configuration)
        @config = config
      end

      # `seeded_count` is how many records Loadwright created for this endpoint's
      # resource. Needed for check 3: an empty response is only suspicious when we
      # know data exists.
      def validate(endpoint:, response:, seeded_count: nil)
        parsed = parse(response)
        record_count = count_records(parsed, endpoint)
        shape = fingerprint(parsed)

        base = {
          record_count: record_count,
          body_bytes: response.body_bytes,
          shape: shape
        }

        # 1. An error status means an error path was measured, not the endpoint.
        if failed_status?(endpoint, response)
          return invalid(:unsuccessful_status, status_detail(endpoint, response), **base)
        end

        # 1b. GRAPHQL ANSWERS 200 FOR A QUERY THAT FAILED COMPLETELY. `data: null` plus
        #     an errors array is a total failure, and the status says 200 -- so the
        #     status check above passes it, and without this the endpoint is reported
        #     as healthy and fast, having done no work at all. Exactly the false
        #     all-clear the three-state model exists to prevent, in the one protocol
        #     where the HTTP status is not the answer.
        if (errors = graphql_errors(parsed))
          return invalid(:graphql_errors, graphql_error_detail(errors), **base)
        end

        # 2. A response that does not match its declared contract means either the
        #    document is stale or the endpoint is misbehaving — either way the
        #    measurement is untrustworthy.
        schema_errors = schema_errors_for(endpoint, parsed)
        if schema_errors&.any? && @config.require_schema_valid_response
          return invalid(:schema_invalid, schema_errors.first(5).join("; "), schema_errors: schema_errors, **base)
        end

        # 3. Seeded 200 posts, got []. A SETUP problem — wrong tenant, wrong
        #    published flag, soft-deleted, wrong association — not a performance
        #    result, and emphatically not a fast healthy endpoint.
        if empty_with_seeded_data?(record_count, seeded_count)
          return invalid(
            :empty_with_seeded_data,
            "#{seeded_count} record(s) were seeded for this resource and the endpoint returned an empty " \
            "collection. The seeded records do not match the endpoint's scope — check for a tenant, a " \
            "published/draft flag, soft deletion, an ownership association, or a default scope. A factory " \
            "trait usually fixes it.",
            **base
          )
        end

        Verdict.new(valid: true, schema_errors: schema_errors, **base)
      end

      # 4. Cross-scale shape consistency, which needs more than one response and so
      #    cannot be part of #validate. If the structure changes between scale
      #    factors, comparing across them is invalid and the slope means nothing.
      def consistent_shape?(shapes)
        present = shapes.compact.uniq
        return true if present.length <= 1

        false
      end

      def shape_inconsistency_detail(shapes)
        distinct = shapes.compact.uniq
        "response structure differed across scale factors (#{distinct.length} distinct shapes: " \
          "#{distinct.map(&:inspect).join(' vs ')}); cross-scale comparison is not valid for this endpoint"
      end

      # Counts records in a parsed body. Public because the correlator needs the same
      # count and the two must agree exactly — queries-per-returned-record divided by
      # a different denominator than the validity gate used is a silent inconsistency.
      def count_records(parsed, endpoint = nil)
        return count_graphql_records(parsed) if endpoint&.graphql? && parsed.is_a?(Hash)

        case parsed
        when Array then parsed.length
        when Hash then count_in_envelope(parsed, endpoint)
        end
      end

      # GraphQL nests the collection under `data` and under the field name, which the
      # envelope keys never match -- so every GraphQL response counted as "not a
      # collection", and the returned-record slope had no input at all.
      #
      # Relay connections are counted by `edges` or `nodes` rather than by the
      # connection object, which is one Hash however many records it holds.
      def count_graphql_records(parsed)
        data = parsed["data"]
        return nil unless data.is_a?(Hash)

        data.each_value do |field|
          count = collection_size(field)
          return count if count
        end

        nil
      end

      def collection_size(field)
        return field.length if field.is_a?(Array)
        return nil unless field.is_a?(Hash)

        %w[edges nodes].each { |key| return field[key].length if field[key].is_a?(Array) }
        nil
      end

      # A structural fingerprint: the top-level type plus the sorted key set of the
      # first element. Deliberately shallow — the question is "did the shape change",
      # not "describe the shape", and a deep fingerprint would report a change every
      # time an optional nested field happened to be absent.
      def fingerprint(parsed)
        case parsed
        when Array
          return "array(empty)" if parsed.empty?

          "array(#{keys_of(parsed.first)})"
        when Hash then "object(#{keys_of(parsed)})"
        when nil then nil
        else parsed.class.name.downcase
        end
      end

      private

      def parse(response)
        return nil if response.body.nil? || response.body.to_s.empty?

        JSON.parse(response.body)
      rescue JSON::ParserError
        nil
      end

      def keys_of(value)
        return value.class.name.downcase unless value.is_a?(Hash)

        value.keys.sort.join(",")
      end

      def count_in_envelope(parsed, endpoint)
        key = ENVELOPE_KEYS.find { |candidate| parsed[candidate].is_a?(Array) }
        return parsed[key].length if key

        # A resource-named key, e.g. { "posts": [...] } — derived from the endpoint's
        # last static path segment rather than from a guess at pluralisation.
        if endpoint
          segment = endpoint.path.split("/").reject { |s| s.empty? || s.start_with?("{") }.last
          return parsed[segment].length if segment && parsed[segment].is_a?(Array)
        end

        # A single-object response is not a collection, and reporting 0 records for it
        # would make every `show` endpoint look empty.
        nil
      end

      # DELIBERATELY NARROW. A REST endpoint may legitimately answer 200 with a body
      # containing the word "errors", so this insists on the GraphQL response shape:
      # a top-level `errors` ARRAY, non-empty, whose entries are objects carrying a
      # `message`. That is what the GraphQL spec requires and what a REST payload is
      # very unlikely to look like by accident.
      #
      # `data` is NOT required alongside it: a query that fails before execution --
      # a syntax error, an unknown field, a failed auth check -- answers with errors
      # and no data at all, and those are the ones most worth catching.
      def graphql_errors(parsed)
        return nil unless @config.require_successful_response
        return nil unless parsed.is_a?(Hash)

        errors = parsed["errors"]
        return nil unless errors.is_a?(Array) && errors.any?
        return nil unless errors.all? { |error| error.is_a?(Hash) && error.key?("message") }

        errors
      end

      def graphql_error_detail(errors)
        first = errors.first["message"].to_s
        count = errors.length

        "the response carried #{count} GraphQL error#{'s' if count > 1} and HTTP 200. " \
          "The first was: #{first}. A GraphQL error means the query did not do the work, " \
          "however fast it answered."
      end

      def failed_status?(endpoint, response)
        return false unless @config.require_successful_response

        return true if response.errored?
        return false if response.success?

        # A declared non-2xx success (a 3xx redirect the doc expects) is honoured.
        !Array(endpoint&.expected_statuses).include?(response.status)
      end

      def status_detail(endpoint, response)
        return "the request raised #{response.error.class}: #{response.error.message}" if response.errored?

        detail = "returned HTTP #{response.status}"
        detail += " (expected #{endpoint.success_status})" if endpoint
        detail += ". An error path was measured, not the endpoint."

        if [401, 403].include?(response.status)
          # TWO causes, named in order of likelihood, because naming only the first
          # sends a reader with the second one to configure something that was never
          # the problem. A 403 from Rails' HostAuthorization middleware never reaches
          # the application at all, and looks identical from out here.
          detail += " A uniform 401/403 across endpoints usually means auth_token_provider is " \
                    "unset or returning an invalid token. If it is every endpoint including " \
                    "public ones, check config.hosts too: Rails' host guard answers 403 before " \
                    "the request reaches your app."
        end

        detail
      end

      # nil when there is no schema — response-analysis.md gates on schema validity
      # only "when a schema exists for that operation". nil is distinct from [], which
      # means "checked, and valid".
      def schema_errors_for(endpoint, parsed)
        schema = endpoint&.success_response_schema
        return nil if schema.nil?
        return ["response body was not parseable JSON"] if parsed.nil?

        schema.errors_for(parsed)
      end

      def empty_with_seeded_data?(record_count, seeded_count)
        return false unless @config.warn_on_empty_response_with_seeded_data
        return false if record_count.nil? || seeded_count.nil?

        record_count.zero? && seeded_count.positive?
      end

      def invalid(reason, detail, **base)
        Verdict.new(valid: false, reason: reason, detail: detail, **base)
      end
    end
  end
end

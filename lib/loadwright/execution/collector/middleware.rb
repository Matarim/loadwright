# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "loadwright/execution/collector/base"
require "loadwright/execution/collector_middleware"

module Loadwright
  module Execution
    module Collector
      # Metrics correlated back over HTTP from the app process.
      #
      # Two channels, deliberately: cheap summary data rides on response headers,
      # and detail (fingerprints, call sites) is fetched from the collection
      # endpoint keyed by request id. Splitting them means a run whose detail fetch
      # fails still has trustworthy counts, and says so — rather than losing the
      # count too and reporting nothing.
      #
      # DEGRADATION IS THE INTERESTING CASE, not the happy path. If the middleware
      # stops answering mid-run, this collector must not keep producing plausible
      # numbers, and must not silently produce zeroes. It records a degradation,
      # which ExecutionContext turns into a new capability epoch — so results
      # collected before the failure keep their original attribution and results
      # after it are marked for what they are.
      class Middleware < Base
        DEGRADED_SIGNALS = %i[
          n_plus_one_pattern_match
          n_plus_one_slope
          queries_per_returned_record
          over_fetch_hint
          time_breakdown_db_view_gc
          explain_index_analysis
        ].freeze

        def initialize(config: Loadwright.configuration, base_url: nil, secret: nil, fetcher: nil)
          super(config: config)
          @base_url = base_url || config.http_target_url
          @secret = secret
          @fetcher = fetcher
        end

        def collector_name = :middleware

        def collect(request, raw_response, capability_epoch: 0)
          count = header_integer(raw_response, CollectorMiddleware::QUERY_COUNT_HEADER)

          # No correlation header means the middleware is not in the response path
          # at all. That is a capability change, not a measurement of zero.
          if count.nil?
            degrade!(DEGRADED_SIGNALS,
                     "the collector middleware stopped attaching correlation headers; query data is " \
                     "no longer being returned by the target")
            return unavailable_metrics(
              request,
              "the collector middleware did not respond on this request; query data was not returned",
              capability_epoch: capability_epoch,
              except: response_derived(raw_response, request)
            )
          end

          detail = fetch_detail(request.request_id)

          RequestMetrics.new(
            request_id: request.request_id,
            collector: collector_name,
            capability_epoch: capability_epoch,
            queries: detail ? Array(detail["queries"]).map { |q| symbolize(q) } : [],
            query_count: Measurement.value(count),
            distinct_query_count: distinct_count(raw_response, detail),
            unattributed_query_count: detail_measurement(detail, "unattributed_query_count"),
            db_runtime_ms: header_measurement(raw_response, CollectorMiddleware::DB_RUNTIME_HEADER),
            view_runtime_ms: header_measurement(raw_response, CollectorMiddleware::VIEW_RUNTIME_HEADER),
            allocations: header_measurement(raw_response, CollectorMiddleware::ALLOCATIONS_HEADER),
            **response_derived(raw_response, request)
          )
        end

        private

        def distinct_count(raw_response, detail)
          from_header = header_integer(raw_response, CollectorMiddleware::DISTINCT_QUERY_HEADER)
          return Measurement.value(from_header) if from_header
          return Measurement.value(detail["distinct_query_count"]) if detail&.key?("distinct_query_count")

          Measurement.unavailable("distinct query count was not returned by the target")
        end

        def header_integer(raw_response, name)
          value = raw_response.header(name)
          return nil if value.nil?

          Integer(value, exception: false)
        end

        def header_measurement(raw_response, name)
          value = raw_response.header(name)
          return Measurement.unavailable("#{name} was not returned by the target") if value.nil?

          numeric = Float(value, exception: false)
          return Measurement.unavailable("#{name} was not numeric: #{value.inspect}") if numeric.nil?

          Measurement.value(numeric)
        end

        def detail_measurement(detail, key)
          return Measurement.unavailable("detail collection did not return #{key}") unless detail&.key?(key)

          Measurement.value(detail[key])
        end

        # A failed detail fetch degrades the detail-dependent signals only. The
        # header-derived counts are still good, and throwing them away because the
        # richer channel failed would lose the most reliable signal this tool has.
        def fetch_detail(request_id)
          return nil if @base_url.nil?

          body = (@fetcher || method(:http_get)).call(detail_uri(request_id))
          JSON.parse(body)
        rescue StandardError => e
          degrade!(%i[over_fetch_hint explain_index_analysis],
                   "the collection endpoint could not be reached (#{e.class}); query fingerprints and " \
                   "call sites are unavailable, though query counts are still being returned")
          nil
        end

        def detail_uri(request_id)
          uri = URI.parse(@base_url)
          uri.path = CollectorMiddleware::COLLECTION_PATH
          uri.query = URI.encode_www_form(request_id: request_id)
          uri
        end

        def http_get(uri)
          request = Net::HTTP::Get.new(uri)
          request[CollectorMiddleware::SECRET_HEADER] = @secret

          response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                         open_timeout: 2, read_timeout: 5) do |http|
            http.request(request)
          end

          raise "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

          response.body
        end

        def symbolize(query)
          {
            fingerprint: query["fingerprint"],
            duration_ms: query["duration_ms"],
            name: query["name"],
            # The exemplar statement, present only when EXPLAIN is enabled. Consumed by
            # ExplainAnalyzer and stripped from every serialisation -- see the note on
            # CollectorMiddleware#redact for why this one field crosses the boundary.
            sql: query["sql"],
            call_site: query["call_site"] && {
              path: query["call_site"]["path"],
              line: query["call_site"]["line"],
              label: query["call_site"]["label"]
            }
          }
        end
      end
    end
  end
end

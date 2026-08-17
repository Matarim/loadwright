# frozen_string_literal: true

require "json"
require "securerandom"
require "loadwright/errors"
require "loadwright/instrumentation/current_request"
require "loadwright/instrumentation/query_tracker"

module Loadwright
  module Execution
    # The GUARDED half of the two-endpoint split. Runs inside the app process and
    # is what makes :http mode's attribution possible at all.
    #
    # Two jobs:
    #
    # 1. Per-request correlation. Reads X-Loadwright-Request-Id off the incoming
    #    request, opens a QueryTracker bucket, and writes cheap summary metrics
    #    back onto the response headers.
    # 2. Detail retrieval. Serves the collection endpoint, keyed by request id,
    #    for data too large for headers (full SQL, call sites).
    #
    # SECURITY REQUIREMENTS, all of them load-bearing (execution-modes.md). Unlike
    # the identity endpoint, this exposes SQL, call sites and timing from the app
    # under test:
    #
    #   * Mounted ONLY while a guard-approved run is active, and unmounted after.
    #   * Refuses to mount at all when the guard flagged the environment as
    #     production-adjacent, regardless of any other config.
    #   * Bound to localhost: a request whose peer is not loopback is refused.
    #   * Requires a per-run shared secret the harness generates at startup,
    #     compared in constant time.
    #   * Subject to the same redaction as the report, applied at COLLECTION time
    #     so unredacted bind values never exist in a response body in the first
    #     place.
    class CollectorMiddleware
      REQUEST_ID_HEADER = "X-Loadwright-Request-Id"
      SECRET_HEADER = "X-Loadwright-Secret"
      COLLECTION_PATH = "/_loadwright/collect"

      # Cheap summary metrics ride back on response headers. Anything larger goes
      # through the collection endpoint.
      QUERY_COUNT_HEADER = "X-Loadwright-Query-Count"
      DISTINCT_QUERY_HEADER = "X-Loadwright-Distinct-Queries"
      DB_RUNTIME_HEADER = "X-Loadwright-Db-Runtime"
      VIEW_RUNTIME_HEADER = "X-Loadwright-View-Runtime"
      ALLOCATIONS_HEADER = "X-Loadwright-Allocations"

      LOOPBACK_ADDRESSES = %w[127.0.0.1 ::1 localhost 0.0.0.0].freeze

      class << self
        attr_reader :active_secret, :tracker

        # Called by the harness after the safety guard approves. Returns the
        # per-run secret.
        def mount!(tracker:, guard: nil, secret: nil)
          if guard&.production_adjacent?
            raise SafetyError,
                  "refusing to mount Loadwright's collection endpoint: the safety guard flagged this " \
                  "environment as production-adjacent. The endpoint exposes SQL, call sites and timing " \
                  "from the app under test, and no configuration overrides this."
          end

          @tracker = tracker
          @active_secret = secret || SecureRandom.hex(32)
        end

        def unmount!
          @tracker = nil
          @active_secret = nil
        end

        def mounted? = !@active_secret.nil?
      end

      def initialize(app)
        @app = app
      end

      def call(env)
        return collect(env) if env["PATH_INFO"] == COLLECTION_PATH

        request_id = env["HTTP_#{REQUEST_ID_HEADER.upcase.tr('-', '_')}"]
        return @app.call(env) unless request_id && self.class.mounted?

        instrumented(env, request_id)
      end

      private

      def instrumented(env, request_id)
        tracker = self.class.tracker
        tracker&.begin_request(request_id)

        allocations_before = allocation_count
        status, headers, body = @app.call(env)

        bucket = tracker&.end_request(request_id)
        [status, headers.merge(summary_headers(env, bucket, allocations_before)), body]
      ensure
        # The bucket is deliberately NOT forgotten here: the harness fetches the
        # detail afterwards, keyed by this id, and the collector cleans up. But the
        # request-id MARKER must be cleared even when the app raised, or the next
        # request served by this Puma thread inherits it and its queries are
        # attributed to a request that already finished.
        Instrumentation::CurrentRequest.clear!
      end

      def summary_headers(env, bucket, allocations_before)
        headers = {}

        if bucket
          headers[QUERY_COUNT_HEADER] = bucket.count.to_s
          headers[DISTINCT_QUERY_HEADER] = bucket.distinct_count.to_s
        end

        # process_action already carries these; reading them off the controller's
        # own accounting is both cheaper and more honest than re-deriving.
        db = env["action_controller.instance"]&.then { |c| c.respond_to?(:db_runtime) ? c.db_runtime : nil }
        headers[DB_RUNTIME_HEADER] = db.to_s if db

        allocated = allocation_count - allocations_before if allocations_before
        headers[ALLOCATIONS_HEADER] = allocated.to_s if allocated

        headers
      end

      def allocation_count
        GC.stat(:total_allocated_objects)
      rescue StandardError
        nil
      end

      # ------------------------------------------------------- collection endpoint

      def collect(env)
        return refuse(404, "not mounted") unless self.class.mounted?
        return refuse(403, "not loopback") unless loopback?(env)
        return refuse(403, "bad secret") unless authorized?(env)

        request_id = rack_query(env)["request_id"]
        return refuse(400, "request_id required") if request_id.to_s.empty?

        tracker = self.class.tracker
        bucket = tracker&.bucket(request_id)
        return refuse(404, "unknown request_id") unless bucket

        payload = {
          "request_id" => request_id,
          "query_count" => bucket.count,
          "distinct_query_count" => bucket.distinct_count,
          "unattributed_query_count" => tracker.unattributed_count,
          "queries" => bucket.queries.map { |q| redact(q) }
        }
        tracker.forget(request_id)

        [200, { "content-type" => "application/json", "cache-control" => "no-store" }, [JSON.generate(payload)]]
      end

      # Bound to localhost. A remote peer cannot reach this even with the secret.
      def loopback?(env)
        address = env["REMOTE_ADDR"].to_s
        LOOPBACK_ADDRESSES.include?(address) || address.start_with?("127.")
      end

      # Constant-time comparison. The secret is per-run and short-lived, but a
      # timing-variable compare here is free to fix and awkward to justify later.
      def authorized?(env)
        provided = env["HTTP_#{SECRET_HEADER.upcase.tr('-', '_')}"].to_s
        expected = self.class.active_secret.to_s
        return false if provided.bytesize != expected.bytesize

        require "openssl"
        OpenSSL.secure_compare(provided, expected)
      end

      # Redaction at COLLECTION time, not render time (reporting.md). Bind values
      # never reach a response body, so they cannot leak into a persisted run
      # record either — fingerprints have already had literals replaced by
      # QueryTracker.fingerprint, and the raw SQL is deliberately never included.
      def redact(query)
        {
          "fingerprint" => query[:fingerprint],
          "duration_ms" => query[:duration_ms],
          "name" => query[:name],
          "call_site" => query[:call_site]
        }
      end

      def rack_query(env)
        require "uri"
        URI.decode_www_form(env["QUERY_STRING"].to_s).to_h
      rescue StandardError
        {}
      end

      def refuse(status, reason)
        [status, { "content-type" => "application/json" }, [JSON.generate("error" => reason)]]
      end
    end
  end
end

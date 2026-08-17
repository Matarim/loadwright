# frozen_string_literal: true

require "loadwright/errors"
require "loadwright/instrumentation/current_request"

module Loadwright
  module Instrumentation
    # Per-request SQL attribution via ActiveSupport::Notifications.
    #
    # THE TRAP THIS CLASS EXISTS TO AVOID. The obvious implementation is for each
    # request to subscribe to "sql.active_record" at its start and unsubscribe at
    # its end. That is wrong, and it corrupts every concurrent run *silently*.
    # AS::N subscribers are PROCESS-GLOBAL: a subscriber registered by one request
    # receives every other in-flight request's SQL events too. Under concurrency
    # you get cross-request metric bleed, and the numbers look entirely plausible
    # — a per-endpoint query count that is simply the wrong endpoint's.
    #
    # So: subscribe ONCE at run start, unsubscribe at run end, and route each
    # event to a bucket by reading the current request id out of
    # ActiveSupport::IsolatedExecutionState. That honours the host app's
    # configured isolation_level instead of hand-rolling fiber or thread locals,
    # which is why this gem's floor is Rails 7.0.
    #
    # KNOWN LIMITATION, documented rather than papered over (AGENTS.md GAP-01):
    # queries issued from a different fiber or thread than the one handling the
    # request do not carry the id. load_async, application-spawned threads, and
    # explicit futures are under-attributed, so an endpoint's query count comes
    # out LOWER than reality — which can hide an N+1 entirely. Rather than let
    # that be invisible, unattributed events are counted in their own bucket and
    # surfaced as a measurement, so a report can say "and 40 queries could not be
    # attributed to any request" instead of quietly dropping them.
    class QueryTracker
      EVENT = "sql.active_record"

      # Set by the harness (Direct) or by the collector middleware (Middleware).
      # Read by the one subscriber. Kept as a constant here because
      # CollectorMiddleware refers to it; the storage itself lives in
      # CurrentRequest, which both subscribers share.
      STATE_KEY = CurrentRequest::KEY

      # Not application queries. Counting them would inflate every endpoint's
      # count by a constant and make cross-scale slopes noisier for no signal.
      IGNORED_NAMES = ["SCHEMA", "TRANSACTION", "EXPLAIN"].freeze
      IGNORED_SQL = /\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE\s+SAVEPOINT|SET\s|SHOW\s|PRAGMA\s)/i

      Bucket = Struct.new(:request_id, :queries, :started_at, keyword_init: true) do
        def count = queries.length

        def distinct_count = queries.map { |q| q[:fingerprint] }.uniq.length
      end

      attr_reader :unattributed_count

      def initialize(config: Loadwright.configuration)
        @config = config
        @buckets = {}
        @unattributed_count = 0
        @unattributed_samples = []
        @mutex = Mutex.new
        @subscriber = nil
        @capture_call_sites = config.detect_n_plus_one || config.serializer_attribution
      end

      # Subscribes once. Idempotent so a double-start (engine plus middleware in
      # the same process during an :in_process run) cannot install two
      # subscribers, which would double every query count.
      def start!
        require "active_support/notifications"
        require "active_support/isolated_execution_state"

        return self if @subscriber

        @subscriber = ::ActiveSupport::Notifications.subscribe(EVENT) do |*args|
          record(::ActiveSupport::Notifications::Event.new(*args))
        end

        disable_query_cache! if @config.disable_query_cache_during_run

        self
      end

      def stop!
        ::ActiveSupport::Notifications.unsubscribe(@subscriber) if @subscriber
        @subscriber = nil
        restore_query_cache!
        self
      end

      def subscribed? = !@subscriber.nil?

      # Opens a bucket and marks this execution context as belonging to it.
      # Called on the thread/fiber that will issue (Direct) or handle
      # (Middleware) the request.
      def begin_request(request_id)
        @mutex.synchronize do
          @buckets[request_id] = Bucket.new(request_id: request_id, queries: [], started_at: monotonic_now)
        end
        CurrentRequest.id = request_id
        request_id
      end

      # Clears the marker and returns the bucket. The bucket is retained so the
      # collector can read it after the response has been returned — under :http
      # the harness asks for it in a separate call.
      def end_request(request_id)
        CurrentRequest.clear!
        bucket(request_id)
      end

      def bucket(request_id) = @mutex.synchronize { @buckets[request_id] }

      def forget(request_id) = @mutex.synchronize { @buckets.delete(request_id) }

      def open_request_ids = @mutex.synchronize { @buckets.keys }

      def unattributed_samples = @mutex.synchronize { @unattributed_samples.dup }

      # Normalises SQL to a fingerprint: literals become `?`, IN-lists collapse,
      # whitespace is squeezed. Two queries that differ only by bind value share a
      # fingerprint, which is what makes duplicate detection work. Exposed as a
      # class method because Analysis and the app-side middleware both need it and
      # they must agree exactly.
      def self.fingerprint(sql)
        # Order matters. Positional binds go before the bare-integer rule, or
        # `$1` becomes `$?` instead of `?`; floats go before integers, or `1.5`
        # becomes `?.?`.
        sql.to_s
           .gsub(/'(?:[^']|'')*'/, "?")           # string literals, including '' escapes
           .gsub(/\$\d+/, "?")                    # Postgres positional binds
           .gsub(/\b\d+\.\d+\b/, "?")
           .gsub(/\b\d+\b/, "?")
           .gsub(/\bIN\s*\(\s*(?:\?\s*,\s*)*\?\s*\)/i, "IN (?)")
           .gsub(/\s+/, " ")
           .strip
      end

      private

      def record(event)
        payload = event.payload
        return if ignored?(payload)

        entry = {
          fingerprint: self.class.fingerprint(payload[:sql]),
          duration_ms: event.duration,
          name: payload[:name],
          cached: !!payload[:cached]
        }
        entry[:call_site] = call_site if @capture_call_sites

        request_id = CurrentRequest.id

        @mutex.synchronize do
          bucket = request_id && @buckets[request_id]
          if bucket
            bucket.queries << entry
          else
            # GAP-01. Counted rather than dropped, so a report can name the gap
            # instead of presenting a quietly-low query count as clean.
            @unattributed_count += 1
            @unattributed_samples << entry if @unattributed_samples.length < 20
          end
        end
      end

      def ignored?(payload)
        return true if IGNORED_NAMES.include?(payload[:name])
        return true if payload[:sql].to_s.match?(IGNORED_SQL)

        false
      end

      # The first frame outside this gem and outside the Ruby/gem load path — the
      # app frame that actually issued the query. This is what makes
      # "N+1 originates in PostSerializer#comments_count" possible instead of a
      # raw stack trace (response-analysis.md Part 5).
      def call_site
        # Only this gem's own lib/, not the whole repository: the frame we want is
        # the first one that is neither Loadwright nor a gem nor stdlib. Excluding
        # the repo root would also exclude a host app that happens to vendor us.
        gem_lib = File.expand_path("../..", __dir__)

        caller_locations(1, 60)&.each do |location|
          path = location.absolute_path || location.path
          next if path.nil?
          next if path.start_with?(gem_lib)
          next if path.include?("/gems/")
          next if path.include?("/lib/ruby/")

          return { path: path, line: location.lineno, label: location.label }
        end

        nil
      end

      # ActiveRecord's query cache dedupes identical queries WITHIN a request. A
      # textbook N+1 — the same SELECT ... WHERE id = ? fired per row — can
      # therefore appear as a single query, producing a confident false negative
      # on precisely the pattern this tool exists to find. Prosopite handles this
      # explicitly and so must we.
      def disable_query_cache!
        unless defined?(::ActiveRecord::Base)
          @query_cache_disable_error = "ActiveRecord is not loaded"
          return
        end

        @query_cache_was_enabled = ::ActiveRecord::Base.connection_pool.query_cache_enabled
        ::ActiveRecord::Base.connection_pool.disable_query_cache!
        @query_cache_disabled = true
      rescue StandardError => e
        # Not fatal, but it must not be silent: every N+1 finding from this run
        # would be potentially undercounted, and the report has to say so.
        @query_cache_disable_error = "#{e.class}: #{e.message}"
      end

      def restore_query_cache!
        return unless @query_cache_disabled
        return unless @query_cache_was_enabled

        ::ActiveRecord::Base.connection_pool.enable_query_cache!
      rescue StandardError
        nil
      ensure
        @query_cache_disabled = false
      end

      def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      public

      # Reported so a run whose query cache could not be turned off says so,
      # rather than presenting possibly-deduped counts as truthful.
      def query_cache_disabled? = @query_cache_disabled == true

      def query_cache_error = @query_cache_disable_error

      def to_h
        {
          subscribed: subscribed?,
          query_cache_disabled: query_cache_disabled?,
          query_cache_error: query_cache_error,
          unattributed_query_count: unattributed_count,
          unattributed_note: if unattributed_count.positive?
                               "queries issued from a fiber or thread other than the one handling the " \
                               "request (load_async, app-spawned threads) cannot be attributed; endpoint " \
                               "query counts are therefore LOWER than reality. See AGENTS.md GAP-01."
                             end
        }.compact
      end
    end
  end
end

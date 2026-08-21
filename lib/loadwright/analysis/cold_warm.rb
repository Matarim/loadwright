# frozen_string_literal: true

require "loadwright/errors"
require "loadwright/measurement"
require "loadwright/analysis/response_correlator"

module Loadwright
  module Analysis
    # The cold pass, kept rather than thrown away.
    #
    # WHY. Warmup requests exist to stop first-request costs polluting the steady-state
    # numbers, and the obvious thing to do with them is discard them. That throws away
    # the interesting case: COLD-CACHE PERFORMANCE IS WHAT USERS HIT right after a
    # deploy, a cache flush, or a restart. An endpoint whose warm p50 is 40ms and whose
    # cold first request is 3s has a worst case nobody has measured, and it is the case
    # that happens to everyone at once.
    #
    # ===========================================================================
    # WHAT WE CAN HONESTLY CLAIM, which is less than "cold".
    #
    # Rails' own cache can be cleared. The database buffer cache and the OS page cache
    # cannot be, not from inside this process and not without root on most systems. So
    # the label is "application-cache cold", never "fully cold" -- the measurement is
    # real and the claim is bounded.
    #
    # AND THE CACHE IS ONLY CLEARED WHEN IT IS OURS TO CLEAR. `Rails.cache.clear` on a
    # Redis or Memcached store wipes a cache other processes are using -- possibly a
    # colleague's, on a shared development instance. That is a diagnostic tool damaging
    # the environment it was pointed at, which is the category of harm the whole safety
    # design exists to prevent, so the store type decides: process-local stores are
    # cleared, shared stores are left alone and the measurement says so.
    # ===========================================================================
    class ColdWarm
      # Stores that live in this process and affect nobody else. Anything not on this
      # list is treated as shared, because the failure of guessing wrong is
      # destroying someone else's data and the failure of being too cautious is a
      # slightly weaker measurement.
      PROCESS_LOCAL_STORES = %w[
        ActiveSupport::Cache::MemoryStore
        ActiveSupport::Cache::NullStore
      ].freeze

      Result = Struct.new(:cold_ms, :warm_ms, :delta_ms, :ratio, :cache_cleared, :cache_store,
                          :label, :caveat, keyword_init: true) do
        def available? = !cold_ms.nil? && !warm_ms.nil?

        # A large gap means the endpoint leans on caching and its worst case is far
        # worse than its average -- worth knowing before a deploy rather than after.
        # BOTH bars, and the absolute one is not belt-and-braces. A ratio computed on
        # sub-millisecond latencies is meaningless -- 0.01ms to 0.05ms is a "5x cold
        # cache dependency" and is actually scheduler jitter. Local requests against a
        # small dev database routinely land there, so the ratio alone would flag
        # essentially every endpoint.
        def notable?(threshold, floor_ms) = available? && !ratio.nil? &&
                                            ratio >= threshold && delta_ms >= floor_ms

        def to_h
          {
            label: label,
            cold_ms: cold_ms&.round(3),
            warm_ms: warm_ms&.round(3),
            delta_ms: delta_ms&.round(3),
            ratio: ratio&.round(2),
            application_cache_cleared: cache_cleared,
            cache_store: cache_store,
            caveat: caveat
          }.compact
        end
      end

      # A cold/warm ratio at or above this is worth reporting. Below it the difference
      # is ordinary first-request cost -- constant lookup, autoloading, a connection
      # being established -- rather than a cache dependency.
      NOTABLE_RATIO = 3.0

      # The cold pass must also be this many milliseconds slower in absolute terms.
      # Below it the difference is ordinary first-request cost -- an autoload, a
      # connection being opened, the scheduler -- rather than a cache dependency, and
      # nobody would act on it.
      MIN_ABSOLUTE_DELTA_MS = 50.0

      LABEL = "application-cache cold"

      NOT_FULLY_COLD = "the database buffer cache and the OS page cache were not reset and cannot be " \
                       "from inside this process, so a genuinely cold machine will be slower still"

      def initialize(config: Loadwright.configuration, cache: nil)
        @config = config
        @injected_cache = cache
      end

      def enabled? = @config.measure_cold_cache

      # Called once per endpoint, before its FIRST cell's warmup pass. Returns whether
      # the application cache was actually cleared, which the result then reports.
      def prepare!
        return false unless enabled?
        return false unless process_local_store?

        cache_store.clear
        true
      rescue StandardError
        false
      end

      def compare(cold_latencies, warm_latencies, cache_cleared: false)
        cold = median(cold_latencies)
        warm = median(warm_latencies)

        Result.new(
          cold_ms: cold, warm_ms: warm,
          delta_ms: cold && warm ? cold - warm : nil,
          ratio: cold && warm && warm.positive? ? cold / warm : nil,
          cache_cleared: cache_cleared,
          cache_store: store_name,
          label: LABEL,
          caveat: caveat_for(cache_cleared)
        )
      end

      # nil when the endpoint had no cold pass at all -- a dry run, or an endpoint that
      # never issued a request. Absent rather than a zero-difference result: "cold and
      # warm were identical" is a claim, and not measuring is not.
      def finding_for(endpoint_key, result)
        return nil if result.nil?
        return nil unless result.notable?(NOTABLE_RATIO, MIN_ABSOLUTE_DELTA_MS)

        ResponseCorrelator::Finding.new(
          kind: :cold_cache_dependency,
          confidence: :medium,
          detail: "the first request after clearing the application cache took " \
                  "#{result.cold_ms.round(1)}ms against a warm #{result.warm_ms.round(1)}ms " \
                  "(#{result.ratio.round(1)}x). This endpoint depends heavily on caching, so its worst " \
                  "case -- right after a deploy or a cache flush -- is far worse than its average. " \
                  "#{result.caveat}",
          evidence: { endpoint: endpoint_key, cold_ms: result.cold_ms.round(3),
                      warm_ms: result.warm_ms.round(3), ratio: result.ratio.round(2),
                      application_cache_cleared: result.cache_cleared }
        )
      end

      def to_h
        {
          enabled: enabled?,
          cache_store: store_name,
          process_local_store: process_local_store?,
          label: LABEL,
          caveat: NOT_FULLY_COLD
        }
      end

      private

      def caveat_for(cache_cleared)
        return NOT_FULLY_COLD if cache_cleared

        return "measure_cold_cache is disabled, so the application cache was left as it was; this is a " \
               "first-request figure rather than a cold one" unless enabled?

        # The honest downgrade. We still report the first-request figure, because it is
        # a real observation -- we just do not claim to have made it cold.
        "the application cache was NOT cleared: #{store_name || 'the cache store'} is shared with other " \
          "processes, and clearing it would affect them. This is a first-request figure, not a cold one."
      end

      def median(values)
        usable = Array(values).compact.map(&:to_f).sort
        return nil if usable.empty?

        usable[(usable.length - 1) / 2]
      end

      def cache_store
        return @injected_cache if @injected_cache
        return nil unless defined?(::Rails) && ::Rails.respond_to?(:cache)

        ::Rails.cache
      rescue StandardError
        nil
      end

      def store_name = cache_store&.class&.name

      def process_local_store?
        PROCESS_LOCAL_STORES.include?(store_name)
      end
    end
  end
end

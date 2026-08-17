# frozen_string_literal: true

require "loadwright/measurement"

module Loadwright
  module Instrumentation
    # Allocation and GC accounting per request.
    #
    # THE HONESTY PROBLEM HERE IS ATTRIBUTION, NOT COLLECTION. GC.stat always
    # returns numbers, and in :in_process mode some of those allocations are
    # Loadwright's own — the harness shares the heap it is measuring. So the numbers
    # exist and their interpretation does not, which is why
    # CapabilityProfile marks clean_memory_attribution unavailable for
    # :in_process rather than this class refusing to collect. A report reads the
    # capability, not the presence of a value.
    #
    # allocated_objects is the signal to lead with, not bytes or RSS:
    #
    #   * object count is near-deterministic run to run, which makes it usable as a
    #     regression signal (run-comparison.md tier 1) where latency is not.
    #   * RSS moves with GC timing rather than with the code under test, so a delta
    #     in it says more about when the collector ran than about the endpoint.
    class MemoryTracker
      Sample = Struct.new(:allocated_objects, :allocated_bytes, :gc_count, :gc_time_ms, keyword_init: true)

      def initialize(config: Loadwright.configuration)
        @config = config
      end

      def enabled? = @config.track_memory_allocations

      # Wraps a block and returns [result, metrics_hash]. The hash is keyed to match
      # RequestMetrics' field names so a collector can splat it straight in.
      def measure
        unless enabled?
          return [yield, unavailable("track_memory_allocations is disabled")]
        end

        before = sample
        result = yield
        after = sample

        [result, delta(before, after)]
      end

      def sample
        stat = GC.stat

        Sample.new(
          allocated_objects: stat[:total_allocated_objects],
          # Not present on every Ruby build or implementation; absent is absent,
          # not zero.
          allocated_bytes: stat[:total_allocated_bytes],
          gc_count: stat[:count],
          gc_time_ms: gc_time_ms
        )
      rescue StandardError, NotImplementedError
        # NotImplementedError is a ScriptError, not a StandardError, and some GC.stat
        # keys genuinely are unimplemented on non-CRuby VMs — so a bare
        # `rescue StandardError` would let it escape and take the run down for a
        # missing memory number.
        nil
      end

      def delta(before, after)
        return unavailable("GC.stat was unavailable") if before.nil? || after.nil?

        {
          allocations: difference(before.allocated_objects, after.allocated_objects,
                                  "GC.stat did not report total_allocated_objects"),
          gc_count: difference(before.gc_count, after.gc_count, "GC.stat did not report a collection count"),
          gc_time_ms: difference(before.gc_time_ms, after.gc_time_ms,
                                 "GC total time is unavailable on this Ruby " \
                                 "(GC::Profiler is not enabled and GC.stat has no total_time_ns)")
        }
      end

      def to_h
        {
          enabled: enabled?,
          gc_total_time_available: !gc_time_ms.nil?
        }
      end

      private

      def difference(before, after, reason)
        return Measurement.unavailable(reason) if before.nil? || after.nil?

        Measurement.value(after - before)
      end

      def unavailable(reason)
        {
          allocations: Measurement.unavailable(reason),
          gc_count: Measurement.unavailable(reason),
          gc_time_ms: Measurement.unavailable(reason)
        }
      end

      # GC.stat's time key is not portable. Rather than turn a missing key into a
      # zero — which would render as "no GC time" in a report — this returns nil and
      # the measurement becomes unavailable with the reason above.
      def gc_time_ms
        stat = GC.stat
        nanoseconds = stat[:total_time_ns]
        return nanoseconds / 1_000_000.0 if nanoseconds

        milliseconds = stat[:time]
        return milliseconds.to_f if milliseconds

        nil
      rescue StandardError, NotImplementedError
        # NotImplementedError is a ScriptError, not a StandardError, and some GC.stat
        # keys genuinely are unimplemented on non-CRuby VMs — so a bare
        # `rescue StandardError` would let it escape and take the run down for a
        # missing memory number.
        nil
      end
    end
  end
end

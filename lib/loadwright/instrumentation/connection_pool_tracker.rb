# frozen_string_literal: true

require "loadwright/measurement"

module Loadwright
  module Instrumentation
    # Connection pool sampling.
    #
    # `ActiveRecord::Base.connection_pool.stat` is the adapter-agnostic signal, and
    # deliberately the primary one: it catches pool exhaustion on SQLite and on a
    # database whose lock introspection Loadwright cannot read, where the Postgres
    # and MySQL probes in the resource guard have nothing to say
    # (resource-contention.md Tier 2).
    #
    # WHAT `waiting` MEANS AND WHY IT IS THE INTERESTING NUMBER. `busy` at the pool
    # size just means the pool is fully used, which under load is what a correctly
    # sized pool looks like. `waiting` above zero means a thread asked for a
    # connection and did not get one — requests are queueing behind the pool rather
    # than behind the database. That is the finding.
    #
    # Under :in_process this is measured against a pool the harness SHARES with the
    # app, so a non-zero `waiting` may be the harness's own doing. CapabilityProfile
    # marks connection_pool_exhaustion unavailable there for exactly that reason;
    # this class still samples, and the capability decides what may be said.
    class ConnectionPoolTracker
      Sample = Struct.new(:size, :busy, :waiting, :dead, :idle, :connections, keyword_init: true) do
        def saturated? = !size.nil? && !busy.nil? && busy >= size

        def starved? = !waiting.nil? && waiting.positive?

        def to_h = { size: size, busy: busy, waiting: waiting, dead: dead, idle: idle, connections: connections }
      end

      def initialize(config: Loadwright.configuration)
        @config = config
        @peak_waiting = 0
        @peak_busy = 0
        @samples = 0
        @mutex = Mutex.new
      end

      def enabled? = @config.track_connection_pool

      def available?
        return false unless enabled?

        defined?(::ActiveRecord::Base) && ::ActiveRecord::Base.respond_to?(:connection_pool)
      end

      def sample
        return nil unless available?

        stat = ::ActiveRecord::Base.connection_pool.stat

        Sample.new(
          size: stat[:size], busy: stat[:busy], waiting: stat[:waiting],
          dead: stat[:dead], idle: stat[:idle], connections: stat[:connections]
        ).tap { |current| record_peak(current) }
      rescue StandardError
        nil
      end

      # Keyed to RequestMetrics' field names so a collector can splat it in.
      def metrics
        current = sample
        return unavailable_metrics(reason_for_unavailability) if current.nil?

        {
          pool_size: measure(current.size),
          pool_busy: measure(current.busy),
          pool_waiting: measure(current.waiting)
        }
      end

      # A peak rather than a per-request value, because pool starvation is a
      # whole-cell property: the request that gets starved is usually not the request
      # that caused it, and a per-request maximum would attribute the pressure to
      # whichever request happened to sample at the wrong moment.
      def peak_waiting = @mutex.synchronize { @peak_waiting }
      def peak_busy = @mutex.synchronize { @peak_busy }

      def reset_peaks!
        @mutex.synchronize do
          @peak_waiting = 0
          @peak_busy = 0
          @samples = 0
        end
      end

      def to_h
        current = sample

        {
          enabled: enabled?,
          available: available?,
          unavailable_reason: available? ? nil : reason_for_unavailability,
          size: current&.size,
          peak_busy: peak_busy,
          peak_waiting: peak_waiting,
          samples: @mutex.synchronize { @samples },
          starved: peak_waiting.positive?
        }.compact
      end

      private

      def record_peak(current)
        @mutex.synchronize do
          @samples += 1
          @peak_waiting = current.waiting if current.waiting && current.waiting > @peak_waiting
          @peak_busy = current.busy if current.busy && current.busy > @peak_busy
        end
      end

      def measure(value)
        return Measurement.unavailable("the connection pool did not report this figure") if value.nil?

        Measurement.value(value)
      end

      def unavailable_metrics(reason)
        {
          pool_size: Measurement.unavailable(reason),
          pool_busy: Measurement.unavailable(reason),
          pool_waiting: Measurement.unavailable(reason)
        }
      end

      def reason_for_unavailability
        return "track_connection_pool is disabled" unless enabled?
        return "ActiveRecord is not loaded; connection pool stats are unavailable" unless defined?(::ActiveRecord::Base)

        "the connection pool could not be read"
      end
    end
  end
end

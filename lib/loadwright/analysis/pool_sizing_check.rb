# frozen_string_literal: true

require "loadwright/errors"
require "loadwright/measurement"
require "loadwright/analysis/response_correlator"

module Loadwright
  module Analysis
    # Server threads versus ActiveRecord pool size, plus what the pool actually did.
    #
    # THE CLASSIC RAILS PRODUCTION INCIDENT. Puma is configured with more threads than
    # the pool has connections, so under load threads queue for a connection and
    # latency collapses in a way that looks exactly like a slow database and is not.
    # The queries are fine; the requests are waiting to be allowed to make one.
    #
    # THIS IS TWO CHECKS, AND THEY DEGRADE SEPARATELY. That separation is the point of
    # the class, not an implementation detail:
    #
    #   STATIC     threads x workers vs pool size. Arithmetic over two config values.
    #              Works everywhere, including :in_process, because it needs no
    #              observation at all -- and it is reported EVEN WHEN NO CONTENTION WAS
    #              SEEN. It is a latent problem, a run at concurrency 5 will not
    #              provoke it, and stating it costs nothing.
    #
    #   OBSERVED   pool waiting counts and the busy high-water mark. Needs a real
    #              server thread pool, so under :in_process it is unavailable -- there
    #              is one thread issuing requests in the harness's own process and
    #              nothing it reports would resemble what a user experiences.
    #
    # So one check yields TWO Measurements, not one blanket unavailable. Collapsing
    # them would throw away the half that works in the default execution mode, which is
    # also the half that catches the incident before it happens.
    #
    # Capability comes from CapabilityProfile, never from config.execution_mode:
    # `pool_vs_threads_static_check` is :partial when only the static half is possible,
    # and `connection_pool_exhaustion` says whether the observed half is worth asking
    # for. An :http run against a remote target has the same transport as an
    # instrumented one and cannot see its pool at all.
    class PoolSizingCheck
      # Parsed from http_server_command, because that is what Loadwright actually
      # launches. Reading Puma's own config file would be more thorough and would also
      # be wrong whenever the command overrides it on the CLI, which is the common case.
      THREADS = /--threads[= ]\s*(?:(\d+):)?(\d+)/
      WORKERS = /(?:-w|--workers)[= ]\s*(\d+)/

      Result = Struct.new(:pool_size, :server_threads, :server_workers, :max_concurrent_demand,
                          :peak_busy, :peak_waiting, :findings, keyword_init: true) do
        def to_h
          {
            pool_size: measurement_to_h(pool_size),
            server_threads: measurement_to_h(server_threads),
            server_workers: measurement_to_h(server_workers),
            max_concurrent_demand: measurement_to_h(max_concurrent_demand),
            peak_busy: measurement_to_h(peak_busy),
            peak_waiting: measurement_to_h(peak_waiting),
            findings: findings.map(&:to_h)
          }
        end

        private

        def measurement_to_h(measurement)
          return nil if measurement.nil?

          measurement.available? ? { value: measurement.value } : { unavailable: measurement.reason }
        end
      end

      Finding = ResponseCorrelator::Finding

      # `pool_provider` is injected rather than read inline, for the reason CLAUDE.md
      # gives about load order: a spec whose premise is "the pool holds 5 connections"
      # would otherwise depend on whether some earlier example happened to boot Rails.
      # It returns the pool size, or nil when there is none to read.
      def initialize(config: Loadwright.configuration, capability:, pool_tracker: nil, pool_provider: nil)
        @config = config
        @capability = capability
        @pool_tracker = pool_tracker
        @pool_provider = pool_provider || method(:active_record_pool_size)
      end

      def enabled? = @config.check_pool_vs_server_threads

      def check
        return disabled_result unless enabled?

        pool = pool_size
        threads = server_threads
        workers = server_workers

        Result.new(
          pool_size: pool, server_threads: threads, server_workers: workers,
          # The demand that matters is PER PROCESS, so this is the thread ceiling and
          # not threads x workers -- see the note on #findings.
          max_concurrent_demand: threads,
          peak_busy: observed(:peak_busy), peak_waiting: observed(:peak_waiting),
          findings: findings(pool, threads, workers)
        )
      end

      private

      # ------------------------------------------------------------------ the static half

      def pool_size
        size = @pool_provider.call
        return Measurement.value(size) if size

        Measurement.unavailable("ActiveRecord is not connected here, so the pool size is unknown")
      rescue StandardError => e
        Measurement.unavailable("the connection pool size could not be read (#{e.class})")
      end

      def active_record_pool_size
        return nil unless active_record_connected?

        ::ActiveRecord::Base.connection_pool.size
      end

      def server_threads
        command = @config.http_server_command.to_s
        return no_server_command(:threads) if command.strip.empty?

        match = command.match(THREADS)
        return Measurement.unavailable(
          "http_server_command does not specify --threads, so the server's thread count is whatever its " \
          "own config sets; Loadwright cannot see it from here"
        ) if match.nil?

        # The MAXIMUM of the min:max pair. Under load a Puma grows to its ceiling, and
        # the ceiling is what the pool has to cover -- taking the floor would clear a
        # `--threads 1:16` against a pool of 5.
        Measurement.value(match[2].to_i)
      end

      def server_workers
        command = @config.http_server_command.to_s
        return no_server_command(:workers) if command.strip.empty?

        match = command.match(WORKERS)
        # Absent means single-mode Puma: one worker, not an unknown. That is a real
        # reading rather than a guess -- no -w flag IS the configuration.
        Measurement.value(match ? match[1].to_i : 1)
      end

      # WORKERS ARE NOT MULTIPLIED IN, and that is the correction worth stating rather
      # than leaving to be inferred from the arithmetic. performance-signals.md phrases
      # the rule as `threads x workers > pool_size`, but each Puma worker is a separate
      # PROCESS with its own ActiveRecord pool -- so `-w 4 --threads 1:4` against a pool
      # of 5 is correctly configured, and multiplying would invent a finding for every
      # clustered Puma in existence. The comparison is per process; the worker count is
      # reported because it changes the total connections the DATABASE sees, which is a
      # different concern (max_connections) from the one this check is about.
      def findings(pool, demand, workers)
        return [] unless pool.available? && demand.available?
        return [] unless demand.value > pool.value

        [Finding.new(
          kind: :pool_smaller_than_server_threads,
          confidence: :high,
          detail: "the server runs up to #{demand.value} thread(s) per process but the ActiveRecord pool " \
                  "holds #{pool.value} connection(s)#{worker_note(workers)}. Under load, threads queue for " \
                  "a connection and latency collapses in a way that looks like a slow database and is not. " \
                  "#{observed_note}Raise the pool to at least #{demand.value}, or lower the thread count.",
          evidence: { server_threads: demand.value, pool_size: pool.value,
                      server_workers: workers.value_or(nil), observed: observed_evidence }
        )]
      end

      # STATED EVEN WHEN NOTHING WAS OBSERVED, and the wording has to make clear which
      # of the two it is. "We saw no contention" alongside a latent misconfiguration
      # reads as a contradiction unless the report says why both are true.
      def observed_note
        waiting = observed(:peak_waiting)

        if waiting.unavailable?
          "This run could not observe pool contention (#{waiting.reason}), so this is a configuration " \
            "finding rather than something that happened. "
        elsif waiting.value.positive?
          "This run observed it: #{waiting.value} thread(s) waiting for a connection at peak. "
        else
          "No contention was observed during this run, which does not clear it -- the run's concurrency " \
            "was probably below the thread count. "
        end
      end

      def worker_note(workers)
        return "" unless workers.available? && workers.value > 1

        " (across #{workers.value} worker processes, each with its own pool)"
      end

      # ---------------------------------------------------------------- the observed half

      # The two halves degrade separately. Capability decides, never the execution mode.
      def observed(field)
        unless @capability.available?(:connection_pool_exhaustion)
          return Measurement.unavailable(
            @capability.reason_for(:connection_pool_exhaustion) || "pool observation is unavailable"
          )
        end

        return Measurement.unavailable("connection pool tracking was not running") if @pool_tracker.nil?

        value = @pool_tracker.public_send(field)
        value.nil? ? Measurement.unavailable("the pool reported no #{field}") : Measurement.value(value)
      end

      def observed_evidence
        {
          peak_busy: observed(:peak_busy).value_or(nil),
          peak_waiting: observed(:peak_waiting).value_or(nil)
        }.compact
      end

      # --------------------------------------------------------------------- helpers

      def active_record_connected?
        defined?(::ActiveRecord::Base) && ::ActiveRecord::Base.connected?
      rescue StandardError
        false
      end

      def no_server_command(field)
        Measurement.unavailable(
          "no http_server_command is configured, so the server's #{field} cannot be read. In :in_process " \
          "mode there is no server; set execution_mode = :http to check this."
        )
      end

      def disabled_result
        Result.new(
          pool_size: Measurement.unavailable("check_pool_vs_server_threads is disabled"),
          server_threads: Measurement.unavailable("check_pool_vs_server_threads is disabled"),
          server_workers: Measurement.unavailable("check_pool_vs_server_threads is disabled"),
          max_concurrent_demand: Measurement.unavailable("check_pool_vs_server_threads is disabled"),
          peak_busy: Measurement.unavailable("check_pool_vs_server_threads is disabled"),
          peak_waiting: Measurement.unavailable("check_pool_vs_server_threads is disabled"),
          findings: []
        )
      end
    end
  end
end

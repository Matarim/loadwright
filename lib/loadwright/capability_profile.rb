# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  # What Loadwright can honestly measure right now, and why it cannot measure
  # the rest.
  #
  # This exists because capability is a property of the *collector*, not of the
  # execution mode. AGENTS.md section 5.1 already says as much — several signals
  # are footnoted "requires collector middleware" rather than "requires :http".
  # An :http run against a remote target that does not load the gem has the same
  # transport as a fully-instrumented one and dramatically less capability.
  #
  # Nothing under analysis/ or reporting/ may branch on config.execution_mode.
  # They consult this object instead, which is the only thing that knows the
  # difference between "measured and fine" and "never measured".
  #
  # Instances are frozen. Capability degrades mid-run (the collector middleware
  # can stop responding; under :http the app process can die outright), and that
  # is modelled by CapabilityTimeline appending a *new* profile rather than by
  # mutating this one — see capability_timeline.rb.
  class CapabilityProfile
    # The signal set is taken verbatim from AGENTS.md section 5.1 so the two
    # cannot drift. A spec asserts they still match.
    SIGNALS = %i[
      n_plus_one_pattern_match
      n_plus_one_slope
      queries_per_returned_record
      over_fetch_hint
      payload_growth_pagination
      response_validity_gate
      time_breakdown_db_view_gc
      explain_index_analysis
      cold_vs_warm_cache
      latency_under_concurrency
      connection_pool_exhaustion
      pool_vs_threads_static_check
      true_client_latency
      clean_memory_attribution
    ].freeze

    STATUSES = %i[available partial unavailable].freeze

    TRANSPORTS = %i[in_process http null].freeze
    COLLECTORS = %i[direct middleware external].freeze

    # One signal's availability, plus the reason when it is not fully available.
    # The reason is what a report prints instead of a number, so it is phrased
    # for a developer deciding what to change, not as an internal error string.
    Capability = Struct.new(:status, :reason) do
      def available?   = status == :available
      def partial?     = status == :partial
      def unavailable? = status == :unavailable

      def to_s
        available? ? "available" : "#{status} (#{reason})"
      end
    end

    NO_QUERY_CAPTURE = "no collector middleware; query data cannot be retrieved from the target"
    NO_REAL_THREADS  = "in-process execution has no server thread pool; use execution_mode = :http"
    NO_APP_PROCESS   = "harness shares the app's process; use execution_mode = :http"

    class << self
      # Derives a profile from the three things that actually determine
      # capability: how requests are issued, how metrics come back, and whether
      # the harness can see the app's own process.
      #
      # Deliberately takes plain symbols rather than transport/collector
      # instances, so the whole analysis and reporting pipeline is testable
      # without booting Rails or opening a socket.
      def derive(transport:, collector:)
        validate!(transport, collector)

        signals = SIGNALS.to_h { |s| [s, Capability.new(:available, nil)] }

        if collector == :external
          # Remote target that does not load the gem. Everything derived from
          # the app's own instrumentation is gone; purely response-derived
          # signals survive. response-analysis.md requires we report the
          # available subset rather than dropping the endpoint entirely.
          %i[
            n_plus_one_pattern_match n_plus_one_slope queries_per_returned_record
            over_fetch_hint time_breakdown_db_view_gc explain_index_analysis
            connection_pool_exhaustion pool_vs_threads_static_check
            clean_memory_attribution
          ].each { |s| signals[s] = Capability.new(:unavailable, NO_QUERY_CAPTURE) }
        end

        if transport == :in_process
          # execution-modes.md: these are suppressed entirely, not reported as
          # zero, and not re-enabled by allow_in_process_threading — threads
          # inside one process sharing a GVL do not measure anything a user
          # would experience.
          signals[:latency_under_concurrency]  = Capability.new(:unavailable, NO_REAL_THREADS)
          signals[:connection_pool_exhaustion] = Capability.new(:unavailable, NO_REAL_THREADS)
          signals[:true_client_latency]        = Capability.new(:unavailable, NO_REAL_THREADS)
          signals[:clean_memory_attribution]   = Capability.new(:unavailable, NO_APP_PROCESS)
          # The static threads-vs-pool comparison still works; the
          # observed-contention half does not.
          signals[:pool_vs_threads_static_check] =
            Capability.new(:partial, "static config comparison only; no observed pool contention in :in_process")
        end

        new(signals)
      end

      private

      def validate!(transport, collector)
        raise ArgumentError, "unknown transport #{transport.inspect}" unless TRANSPORTS.include?(transport)
        raise ArgumentError, "unknown collector #{collector.inspect}" unless COLLECTORS.include?(collector)
      end
    end

    attr_reader :signals

    def initialize(signals)
      unknown = signals.keys - SIGNALS
      raise ArgumentError, "unknown signal(s): #{unknown.join(', ')}" if unknown.any?

      missing = SIGNALS - signals.keys
      raise ArgumentError, "missing signal(s): #{missing.join(', ')}" if missing.any?

      @signals = signals.freeze
      freeze
    end

    def [](signal)
      @signals.fetch(signal) { raise ArgumentError, "unknown signal #{signal.inspect}" }
    end

    def available?(signal)   = self[signal].available?
    def unavailable?(signal) = self[signal].unavailable?
    def partial?(signal)     = self[signal].partial?

    def reason_for(signal) = self[signal].reason

    def available_signals   = SIGNALS.select { |s| available?(s) }
    def unavailable_signals = SIGNALS.select { |s| unavailable?(s) }

    # Returns a NEW profile with the named signals downgraded. Value semantics
    # are the point: a mid-run degradation produces a distinct profile that
    # later requests are attributed to, leaving already-collected results
    # attributed to the profile that was actually in effect when they ran.
    def degrade(*signals_to_degrade, reason:, status: :unavailable)
      raise ArgumentError, "unknown status #{status.inspect}" unless STATUSES.include?(status)
      raise ArgumentError, "a degradation requires a reason" if reason.to_s.strip.empty?

      updated = @signals.dup
      signals_to_degrade.flatten.each do |signal|
        raise ArgumentError, "unknown signal #{signal.inspect}" unless SIGNALS.include?(signal)

        updated[signal] = Capability.new(status, reason.to_s)
      end
      self.class.new(updated)
    end

    # True when `other` can measure everything this profile can. Used by the
    # run comparator: two runs are only fully comparable where their
    # capabilities overlap, and run-comparison.md allows a partial comparison
    # on the intersection rather than refusing outright.
    def intersect(other)
      merged = SIGNALS.to_h do |signal|
        mine = self[signal]
        theirs = other[signal]
        [signal, mine.available? && theirs.available? ? mine : worse_of(mine, theirs)]
      end
      self.class.new(merged)
    end

    def to_h
      @signals.transform_values { |c| { status: c.status, reason: c.reason } }
    end

    def ==(other)
      other.is_a?(self.class) && other.signals == signals
    end
    alias eql? ==

    def hash = [self.class, @signals].hash

    private

    def worse_of(one, two)
      order = { available: 0, partial: 1, unavailable: 2 }
      order[one.status] >= order[two.status] ? one : two
    end
  end
end

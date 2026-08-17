# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Engine
    # Aborts a run whose endpoints are simply broken — wrong auth, missing
    # route, uniform 500s — rather than continuing to hammer them for the rest of
    # the matrix.
    #
    # Specified in references/production-safety.md (circuit breaker) and
    # references/resource-contention.md Part 6.
    #
    # THE SPLIT THAT MATTERS. This breaker and the resource guard own DISJOINT
    # error classes, and the split is structural rather than something an
    # operator tunes:
    #
    #   breaker -> "this endpoint is broken"        (auth, routing, 500s)
    #   guard   -> "the database is under pressure" (locks, pool, timeouts)
    #
    # Contention naturally produces errors. Counting them here makes the two
    # mechanisms fight: the breaker aborts runs the guard was handling
    # correctly. So contention events are recorded SEPARATELY and never enter
    # the error-rate numerator. resource-contention.md Part 6 documents that an
    # earlier draft told operators to raise max_error_rate_before_abort to work
    # around this; that guidance is withdrawn, because the code can classify it.
    #
    # Both counts are reported, so neither mechanism hides the other's activity.
    class CircuitBreaker
      Trip = Struct.new(:error_rate, :errors, :observations, :threshold, keyword_init: true) do
        def message
          format(
            "circuit breaker tripped: %<errors>d of %<observations>d requests failed (%<pct>.1f%%), " \
            "over the %<threshold>.1f%% threshold in max_error_rate_before_abort",
            errors: errors, observations: observations, pct: error_rate * 100, threshold: threshold * 100
          )
        end
      end

      # Below this, one unlucky request is a majority of the sample. Tripping on
      # a 1/1 error rate would abort most runs during their first warmup
      # request, which is a worse failure than reacting one cell late.
      MINIMUM_OBSERVATIONS = 10

      attr_reader :observations, :errors, :contention_events, :trip

      def initialize(config: Loadwright.configuration, minimum_observations: MINIMUM_OBSERVATIONS)
        @threshold = config.max_error_rate_before_abort
        @minimum_observations = minimum_observations
        @observations = 0
        @errors = 0
        @contention_events = 0
        @trip = nil
        @mutex = Mutex.new
      end

      def record_success
        @mutex.synchronize { @observations += 1 }
        nil
      end

      # An endpoint-level failure: bad status, unexpected exception, anything the
      # guard did not claim.
      def record_error
        @mutex.synchronize do
          @observations += 1
          @errors += 1
          @trip ||= evaluate
        end
        nil
      end

      # A contention event, counted for the report and EXCLUDED from the
      # error-rate numerator. It still increments observations: a run that spent
      # most of its requests in contention should not have its remaining
      # handful of real errors amplified into a 100% error rate.
      def record_contention
        @mutex.synchronize do
          @observations += 1
          @contention_events += 1
        end
        nil
      end

      def error_rate
        @mutex.synchronize { @observations.zero? ? 0.0 : @errors.fdiv(@observations) }
      end

      def tripped? = !@mutex.synchronize { @trip }.nil?

      # Called by the engine between cells. Raises so the run unwinds through
      # its normal ensure path, which is what writes the partial report and
      # cleans up seeded rows.
      def check!
        trip = @mutex.synchronize { @trip }
        return false unless trip

        raise RunAborted.new(trip.message, rung: :circuit_breaker)
      end

      def to_h
        @mutex.synchronize do
          {
            threshold: @threshold,
            observations: @observations,
            errors: @errors,
            error_rate: @observations.zero? ? 0.0 : @errors.fdiv(@observations),
            contention_events: @contention_events,
            contention_excluded_from_error_rate: true,
            tripped: !@trip.nil?,
            trip_reason: @trip&.message
          }
        end
      end

      private

      # Called with the mutex held.
      def evaluate
        return nil if @observations < @minimum_observations

        rate = @errors.fdiv(@observations)
        return nil if rate <= @threshold

        Trip.new(error_rate: rate, errors: @errors, observations: @observations, threshold: @threshold)
      end
    end
  end
end

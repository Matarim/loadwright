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

      # Above this share of the errors, ONE endpoint is the problem rather than the
      # run being broken. 0.8 leaves room for a couple of unrelated failures without
      # losing the concentration signal.
      CONCENTRATION_THRESHOLD = 0.8

      attr_reader :observations, :errors, :contention_events, :trip

      def initialize(config: Loadwright.configuration, minimum_observations: MINIMUM_OBSERVATIONS)
        @threshold = config.max_error_rate_before_abort
        @minimum_observations = minimum_observations
        @observations = 0
        @errors = 0
        @contention_events = 0
        @errors_by_endpoint = Hash.new(0)
        @endpoints_seen = []
        @quarantined = []
        @trip = nil
        @mutex = Mutex.new
      end

      def record_success(endpoint_key = nil)
        @mutex.synchronize do
          @observations += 1
          note_endpoint(endpoint_key)
        end
        nil
      end

      # An endpoint-level failure: bad status, unexpected exception, anything the
      # guard did not claim.
      def record_error(endpoint_key = nil)
        @mutex.synchronize do
          @observations += 1
          @errors += 1
          @errors_by_endpoint[endpoint_key] += 1 if endpoint_key
          note_endpoint(endpoint_key)
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

      # ONE BROKEN ENDPOINT SHOULD NOT COST THE OTHER NINETEEN. When the errors are
      # concentrated in a single endpoint, the engine quarantines that endpoint and
      # keeps going instead of aborting the run -- which is what "this endpoint is
      # broken" should mean. Errors spread ACROSS endpoints still trip: that is the
      # case the breaker exists for.
      def quarantine_candidate
        @mutex.synchronize { concentrated_endpoint }
      end

      def quarantine!(endpoint_key)
        @mutex.synchronize do
          @quarantined << endpoint_key unless @quarantined.include?(endpoint_key)
          # Its errors stop counting: it is no longer being measured, and leaving them
          # in the numerator would abort the run for an endpoint already set aside.
          @errors -= @errors_by_endpoint[endpoint_key]
          @observations -= @errors_by_endpoint[endpoint_key]
          @errors_by_endpoint.delete(endpoint_key)
          @trip = nil
        end
        nil
      end

      def quarantined = @mutex.synchronize { @quarantined.dup }

      def to_h
        @mutex.synchronize do
          {
            threshold: @threshold,
            quarantined_endpoints: @quarantined.dup,
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

        # Deferred, not cancelled: the engine quarantines the endpoint and the next
        # error re-evaluates without it.
        return nil if concentrated_endpoint

        Trip.new(error_rate: rate, errors: @errors, observations: @observations, threshold: @threshold)
      end

      def note_endpoint(key)
        @endpoints_seen << key if key && !@endpoints_seen.include?(key)
      end

      # Called with the mutex held. nil unless one endpoint owns nearly all the errors
      # AND the run has more than one endpoint to carry on WITH -- quarantining the
      # only endpoint under test would leave the run measuring nothing.
      def concentrated_endpoint
        return nil if (@endpoints_seen - @quarantined).length < 2

        worst, count = @errors_by_endpoint.max_by { |_, value| value }
        return nil if worst.nil?

        count.fdiv(@errors) >= CONCENTRATION_THRESHOLD ? worst : nil
      end
    end
  end
end

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
      Trip = Struct.new(:error_rate, :errors, :observations, :threshold, :worst_endpoints,
                        keyword_init: true) do
        # NAMES WHO FAILED. "31 of 81 failed" gives a reader no way to tell whether the
        # failures were spread across the surface or came from three endpoints they
        # already knew about -- which is the difference between "your app is broken"
        # and "these three are, and everything else was fine until the run died around
        # them".
        def message
          base = format(
            "circuit breaker tripped: %<errors>d of %<observations>d requests failed (%<pct>.1f%%), " \
            "over the %<threshold>.1f%% threshold in max_error_rate_before_abort",
            errors: errors, observations: observations, pct: error_rate * 100, threshold: threshold * 100
          )
          return base if Array(worst_endpoints).empty?

          named = worst_endpoints.map { |key, count| "#{key} (#{count})" }.join(", ")
          "#{base}. Most of the failures came from: #{named}"
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

      # An endpoint failing at or above this rate is broken, whatever anything else is
      # doing. The share rule above cannot see this: when SEVERAL endpoints are each
      # failing on nearly every request, no single one owns 80% of the errors, so
      # nothing was a candidate and the whole run aborted around them.
      ENDPOINT_FAILURE_THRESHOLD = 0.8

      # Below this, an endpoint has not been asked enough times to call it broken.
      MINIMUM_ENDPOINT_OBSERVATIONS = 5

      # QUARANTINE IS FOR A SUBSET, NOT FOR THE SURFACE. If most of the surface is
      # failing, that is spread rather than concentration -- a wrong token, an app that
      # is down -- and the run should abort rather than quarantine its way through the
      # entire matrix one endpoint at a time. Kept strictly below half so "most of the
      # API is broken" can never be reclassified as a series of local problems.
      MAX_BROKEN_SHARE = 0.5

      attr_reader :observations, :errors, :contention_events, :trip

      # HOW MANY ENDPOINTS THE RUN PLANS TO EXERCISE, set by the engine before the
      # sweeps. Without it the spread check can only count endpoints SEEN SO FAR, and
      # early in a run that is whichever ones happened to be exercised first -- so a
      # cluster of broken endpoints at the front of the matrix looks like "everything
      # is broken" and aborts before a single healthy one is reached. That order
      # dependence is exactly the failure this mechanism exists to remove: widening an
      # allowlist must never REMOVE coverage that was already being collected.
      attr_accessor :expected_endpoints

      def initialize(config: Loadwright.configuration, minimum_observations: MINIMUM_OBSERVATIONS)
        @threshold = config.max_error_rate_before_abort
        @minimum_observations = minimum_observations
        @observations = 0
        @errors = 0
        @contention_events = 0
        @errors_by_endpoint = Hash.new(0)
        @observations_by_endpoint = Hash.new(0)
        @quarantine_reasons = {}
        @endpoints_seen = []
        @quarantined = []
        @trip = nil
        @mutex = Mutex.new
      end

      def record_success(endpoint_key = nil)
        @mutex.synchronize do
          @observations += 1
          @observations_by_endpoint[endpoint_key] += 1 if endpoint_key
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
          if endpoint_key
            @errors_by_endpoint[endpoint_key] += 1
            @observations_by_endpoint[endpoint_key] += 1
          end
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
          unless @quarantined.include?(endpoint_key)
            @quarantined << endpoint_key
            # RECORDED, so widening an allowlist and getting a pile of quarantines is
            # legible: a reader can see the failures came from a specific known subset
            # rather than from the surface they were trying to add.
            @quarantine_reasons[endpoint_key] = {
              errors: @errors_by_endpoint[endpoint_key],
              observations: @observations_by_endpoint[endpoint_key]
            }
          end
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
            quarantine_reasons: @quarantine_reasons.transform_values(&:dup),
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

        Trip.new(error_rate: rate, errors: @errors, observations: @observations, threshold: @threshold,
                 worst_endpoints: @errors_by_endpoint.sort_by { |_, count| -count }.first(3))
      end

      def note_endpoint(key)
        @endpoints_seen << key if key && !@endpoints_seen.include?(key)
      end

      # Called with the mutex held. nil unless there is an endpoint worth setting aside
      # AND the run has more than one endpoint to carry on WITH -- quarantining the
      # only endpoint under test would leave the run measuring nothing.
      #
      # TWO RULES, because one of them could not see the case that mattered.
      #
      # The SHARE rule catches one endpoint owning nearly all the errors. It is blind
      # to several endpoints each failing on nearly every request: no single one owns
      # 80% of the errors, so nothing was a candidate and the run aborted around them.
      # Observed for real -- a user widened included_paths to reach a newly recovered
      # surface, the breaker tripped at 38%, and every one of those failures was on the
      # OLD surface from endpoints already known to be broken. The run died before
      # reaching the endpoints the widening was for. Adding coverage removed coverage,
      # and nothing in the output said the new surface was innocent.
      #
      # The RATE rule catches it directly: an endpoint failing on nearly every request
      # is broken whatever anything else is doing, which is what the breaker's own
      # "this endpoint is broken" half is supposed to mean.
      def concentrated_endpoint
        return nil if (@endpoints_seen - @quarantined).length < 2

        by_share = endpoint_owning_most_errors
        return by_share if by_share

        broken = broken_endpoints
        return nil if broken.empty?
        return nil if broken.length > (surface_size * MAX_BROKEN_SHARE)

        broken.max_by { |key| @errors_by_endpoint[key] }
      end

      def endpoint_owning_most_errors
        worst, count = @errors_by_endpoint.max_by { |_, value| value }
        return nil if worst.nil? || @errors.zero?

        count.fdiv(@errors) >= CONCENTRATION_THRESHOLD ? worst : nil
      end

      # Endpoints failing on nearly every request they were sent.
      def broken_endpoints
        @errors_by_endpoint.keys.select do |key|
          seen = @observations_by_endpoint[key]
          seen >= MINIMUM_ENDPOINT_OBSERVATIONS &&
            @errors_by_endpoint[key].fdiv(seen) >= ENDPOINT_FAILURE_THRESHOLD
        end
      end

      # The whole surface where the engine told us how big it is, and what we have seen
      # otherwise. Counting only what has been seen makes the answer depend on the order
      # the matrix happens to run in.
      def surface_size
        [expected_endpoints.to_i, @endpoints_seen.length].max
      end
    end
  end
end

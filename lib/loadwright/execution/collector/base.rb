# frozen_string_literal: true

require "loadwright/errors"
require "loadwright/execution/request_metrics"

module Loadwright
  module Execution
    module Collector
      # HOW METRICS COME BACK. The second of the three seams, and the one that
      # owns CAPABILITY.
      #
      # This is the design decision the whole execution layer is arranged around:
      # capability is a property of the collector, not of the execution mode. The
      # same :http transport paired with Middleware and with External produces the
      # same requests and dramatically different confidence. Anything that
      # derived "unavailable" from execution_mode would be right in the common
      # case and wrong in exactly the degraded-remote case — where a confidently
      # wrong number does the most damage.
      #
      # Subclasses declare #collector_name, which CapabilityProfile.derive keys
      # off, and return a RequestMetrics whose every field is a Measurement.
      class Base
        attr_reader :config

        def initialize(config: Loadwright.configuration)
          @config = config
          @side_effects = {}
          @in_flight = {}
          @overlapped = {}
          @side_effect_mutex = Mutex.new
        end

        # :direct | :middleware | :external — the symbol CapabilityProfile keys on.
        def collector_name = raise NotImplementedError, "#{self.class}#collector_name"

        def start_run! = self

        def stop_run! = self

        # Called before the request is issued, on the thread that will issue it.
        def begin_request(request)
          note_side_effect_baseline(request)
        end

        # Called after. Returns RequestMetrics.
        def collect(_request, _raw_response, capability_epoch: 0)
          raise NotImplementedError, "#{self.class}#collect"
        end

        # Set by a collector that discovered mid-request that it can no longer
        # collect — a middleware that stopped answering, an app process that died.
        # The ExecutionContext reads this and opens a new capability epoch, so
        # results already collected keep their original attribution.
        def degradation = @degradation

        def degraded? = !@degradation.nil?

        private

        # Records the FIRST degradation only. A middleware failing on every
        # subsequent request must not overwrite the original cause with the
        # hundredth instance of it.
        def degrade!(signals, reason)
          @degradation ||= { signals: Array(signals), reason: reason }
        end

        def unavailable_metrics(request, reason, capability_epoch:, except: {})
          RequestMetrics.unavailable(
            request_id: request.request_id,
            reason: reason,
            collector: collector_name,
            capability_epoch: capability_epoch,
            except: except
          )
        end

        # Response-derived metrics, available to EVERY collector including
        # External, because they need nothing from the app's instrumentation.
        #
        # Mail and job counts are DELTAS over the request, not the totals the test
        # adapters have accumulated. The raw totals grow monotonically across a run, so
        # reporting them per request would show request 500 enqueuing 500 jobs and
        # request 1 enqueuing one -- a number that rises with nothing but time.
        def response_derived(raw_response, request = nil)
          {
            mail_deliveries: side_effect_delta(request, :mail, mail_count),
            jobs_enqueued: side_effect_delta(request, :jobs, job_count)
          }.compact.merge(latency_note(raw_response))
        end

        # THE BASELINE, taken before the request is issued.
        #
        # Also records whether anything else was in flight. The counters are
        # PROCESS-GLOBAL, so when two requests overlap a delta attributes one's jobs to
        # the other -- and a wrong attribution is worse than an absent one, because
        # "this endpoint enqueues 200 jobs" is exactly the kind of finding someone acts
        # on. Overlap is detected rather than inferred from the configured concurrency:
        # what matters is whether requests ACTUALLY overlapped.
        def note_side_effect_baseline(request)
          return if request.nil?

          @side_effect_mutex.synchronize do
            @side_effects[request.request_id] = { mail: mail_count&.value_or(nil), jobs: job_count&.value_or(nil) }

            if @in_flight.any?
              @overlapped[request.request_id] = true
              @in_flight.each_key { |id| @overlapped[id] = true }
            end
            @in_flight[request.request_id] = true
          end
        end

        def side_effect_delta(request, key, current)
          return nil if current.nil?
          return current if request.nil?

          baseline, overlapped = @side_effect_mutex.synchronize do
            @in_flight.delete(request.request_id)
            [@side_effects.delete(request.request_id), @overlapped.delete(request.request_id)]
          end

          if overlapped
            return Measurement.unavailable(
              "#{key} counts are process-global, and another request was in flight at the same time; " \
              "a per-request delta would attribute its #{key} to this one"
            )
          end

          before = baseline && baseline[key]
          return Measurement.unavailable("no baseline #{key} count was taken before this request") if
            before.nil?

          Measurement.value(current.value - before)
        end

        def latency_note(_raw_response) = {}

        # Containment forces these to :test adapters, which record instead of
        # performing — so volume per request becomes a countable signal. A request
        # enqueuing 200 jobs is a finding.
        def mail_count
          return nil unless defined?(::ActionMailer::Base) && ::ActionMailer::Base.respond_to?(:deliveries)

          Measurement.value(::ActionMailer::Base.deliveries.length)
        rescue StandardError
          nil
        end

        def job_count
          adapter = defined?(::ActiveJob::Base) ? ::ActiveJob::Base.queue_adapter : nil
          return nil unless adapter.respond_to?(:enqueued_jobs)

          Measurement.value(adapter.enqueued_jobs.length)
        rescue StandardError
          nil
        end
      end
    end
  end
end

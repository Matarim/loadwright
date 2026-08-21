# frozen_string_literal: true

require "loadwright/execution/collector/base"
require "loadwright/instrumentation/query_tracker"

module Loadwright
  module Execution
    module Collector
      # Shares the app's process, so it reads ActiveSupport::Notifications, GC
      # stats and the connection pool directly. No correlation machinery is needed
      # for the transport — but the SUBSCRIBER machinery is still needed, and is
      # exactly the same machinery, because AS::N subscribers are process-global
      # whether or not there is a socket in the picture.
      #
      # That last point is easy to get wrong. "In-process means attribution is
      # free" is true only of single-threaded runs. Under
      # allow_in_process_threading there are concurrent requests in one process
      # and one global subscriber, which is the identical routing problem :http has
      # — so both collectors use one QueryTracker rather than each having its own
      # idea of correlation.
      class Direct < Base
        def initialize(config: Loadwright.configuration, tracker: nil)
          super(config: config)
          @tracker = tracker || Instrumentation::QueryTracker.new(config: config)
        end

        attr_reader :tracker

        def collector_name = :direct

        def start_run!
          @tracker.start!
          self
        end

        def stop_run!
          @tracker.stop!
          self
        end

        def begin_request(request)
          @tracker.begin_request(request.request_id)
        end

        def collect(request, raw_response, capability_epoch: 0)
          bucket = @tracker.end_request(request.request_id)

          # No bucket means begin_request was never called for this id, which is a
          # harness bug rather than an app property. Reported as unavailable with
          # that stated, rather than as zero queries.
          unless bucket
            return unavailable_metrics(
              request,
              "no query bucket was opened for this request; correlation was not started",
              capability_epoch: capability_epoch
            )
          end

          @tracker.forget(request.request_id)

          RequestMetrics.new(
            request_id: request.request_id,
            collector: collector_name,
            capability_epoch: capability_epoch,
            queries: bucket.queries,
            query_count: Measurement.value(bucket.count),
            distinct_query_count: Measurement.value(bucket.distinct_count),
            unattributed_query_count: Measurement.value(@tracker.unattributed_count),
            db_runtime_ms: sum_query_duration(bucket),
            **process_metrics,
            **pool_metrics,
            **response_derived(raw_response, request)
          )
        end

        private

        def sum_query_duration(bucket)
          Measurement.value(bucket.queries.sum { |q| q[:duration_ms].to_f }.round(3))
        end

        # Allocation and GC numbers are collected but they measure a heap the
        # harness shares with the app. CapabilityProfile marks
        # clean_memory_attribution unavailable for :in_process precisely so these
        # cannot be read as the app's own footprint — the number exists, its
        # interpretation does not.
        def process_metrics
          stat = GC.stat

          {
            allocations: Measurement.value(stat[:total_allocated_objects]),
            gc_count: Measurement.value(stat[:count])
          }
        rescue StandardError => e
          {
            allocations: Measurement.unavailable("GC.stat unavailable: #{e.class}"),
            gc_count: Measurement.unavailable("GC.stat unavailable: #{e.class}")
          }
        end

        def pool_metrics
          unless defined?(::ActiveRecord::Base)
            reason = "ActiveRecord is not loaded; connection pool stats are unavailable"
            return {
              pool_size: Measurement.unavailable(reason),
              pool_busy: Measurement.unavailable(reason),
              pool_waiting: Measurement.unavailable(reason)
            }
          end

          stat = ::ActiveRecord::Base.connection_pool.stat

          {
            pool_size: Measurement.value(stat[:size]),
            pool_busy: Measurement.value(stat[:busy]),
            pool_waiting: Measurement.value(stat[:waiting])
          }
        rescue StandardError => e
          reason = "connection pool stats unavailable: #{e.class}: #{e.message}"
          {
            pool_size: Measurement.unavailable(reason),
            pool_busy: Measurement.unavailable(reason),
            pool_waiting: Measurement.unavailable(reason)
          }
        end
      end
    end
  end
end

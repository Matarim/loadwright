# frozen_string_literal: true

require "loadwright/measurement"
require "loadwright/instrumentation/current_request"

module Loadwright
  module Analysis
    # Splits a request's wall time into db / view / gc / other.
    #
    # WHY THIS IS WORTH MORE THAN ITS SIZE. It is what stops the report blaming the
    # database for a serialisation problem. An endpoint at 400ms with 3 queries has
    # no query-count finding at all, and a query-focused tool has nothing to say
    # about it — so the developer goes looking at SQL, finds nothing, and concludes
    # the tool was wrong. If 340ms of that is view time, the actual advice is
    # "your serialiser is the problem", which is a completely different afternoon.
    # AGENTS.md §9.2 has the agent-facing version: redirect the user AWAY from query
    # optimisation when view time dominates.
    #
    # AND IT IS CHEAP, which is the other reason to have it: Rails already computes
    # db_runtime and view_runtime and puts them on the process_action payload. There
    # is nothing to instrument, only something to read — so this costs one subscriber
    # rather than any per-query accounting.
    #
    # ONE PREREQUISITE, worth knowing because it fails silently. `db_runtime` is put
    # on the payload by ActiveRecord::Railties::ControllerRuntime, which is mixed in
    # by `active_record/railtie` — NOT by requiring `active_record` alone. An app
    # that loads the latter has working models and a permanently nil db_runtime.
    # `view_runtime` comes from ActionView's equivalent, so an API-only app that
    # renders JSON without ActionView reports nil there too. Both cases surface as
    # `unavailable` with a reason rather than as 0.0, because "serialisation is free"
    # is a claim and "we could not measure serialisation" is not.
    #
    # Subscribed ONCE per run and routed by request id, for the same reason
    # QueryTracker is: AS::N subscribers are process-global, so a per-request
    # subscriber would receive every concurrent request's events and attribute them
    # to whoever happened to be listening.
    class TimeBreakdown
      EVENT = "process_action.action_controller"

      # `other` is deliberately a named residual rather than an omission. It is where
      # middleware, authentication, external HTTP, and controller Ruby live, and a
      # large `other` is a real finding — it is just not one this breakdown can
      # attribute further, and saying so beats silently dropping the time.
      COMPONENTS = %i[db view gc other].freeze

      Breakdown = Struct.new(:total_ms, :db_ms, :view_ms, :gc_ms, :other_ms, :controller, :action,
                             keyword_init: true) do
        def share(component)
          value = public_send(:"#{component}_ms")
          return nil if value.nil? || total_ms.nil? || total_ms.zero?

          value / total_ms
        end

        def dominant
          shares = COMPONENTS.filter_map { |c| [c, share(c)] if share(c) }
          return nil if shares.empty?

          shares.max_by(&:last).first
        end

        def to_h
          {
            total_ms: total_ms&.round(3), db_ms: db_ms&.round(3), view_ms: view_ms&.round(3),
            gc_ms: gc_ms&.round(3), other_ms: other_ms&.round(3),
            dominant: dominant, controller: controller, action: action
          }.compact
        end
      end

      def initialize(config: Loadwright.configuration)
        @config = config
        @breakdowns = {}
        @mutex = Mutex.new
        @subscriber = nil
      end

      def enabled? = @config.track_time_breakdown

      def start!
        return self unless enabled?
        return self if @subscriber

        require "active_support/notifications"

        @subscriber = ::ActiveSupport::Notifications.subscribe(EVENT) do |*args|
          record(::ActiveSupport::Notifications::Event.new(*args))
        end

        self
      end

      def stop!
        ::ActiveSupport::Notifications.unsubscribe(@subscriber) if @subscriber
        @subscriber = nil
        self
      end

      def subscribed? = !@subscriber.nil?

      def for_request(request_id) = @mutex.synchronize { @breakdowns[request_id] }

      def forget(request_id) = @mutex.synchronize { @breakdowns.delete(request_id) }

      # Keyed to RequestMetrics' field names.
      def metrics_for(request_id)
        breakdown = for_request(request_id)
        return unavailable_metrics(reason) if breakdown.nil?

        {
          db_runtime_ms: measure(breakdown.db_ms, "Rails did not report db_runtime for this request"),
          view_runtime_ms: measure(breakdown.view_ms, "Rails did not report view_runtime for this request")
        }
      end

      def to_h
        {
          enabled: enabled?,
          subscribed: subscribed?,
          requests_measured: @mutex.synchronize { @breakdowns.length }
        }
      end

      private

      def record(event)
        request_id = Instrumentation::CurrentRequest.id
        return if request_id.nil?

        payload = event.payload
        total = event.duration
        db = payload[:db_runtime]
        view = payload[:view_runtime]
        gc = gc_time_for(event)

        # Clamped at zero. db_runtime and view_runtime are measured independently and
        # can sum to slightly more than the total on a fast request; a negative
        # `other` would be nonsense in a report, and a small overlap is not worth
        # inventing a fifth component for.
        accounted = [db, view, gc].compact.sum
        other = [total - accounted, 0.0].max

        breakdown = Breakdown.new(
          total_ms: total, db_ms: db&.to_f, view_ms: view&.to_f, gc_ms: gc,
          other_ms: other, controller: payload[:controller], action: payload[:action]
        )

        @mutex.synchronize { @breakdowns[request_id] = breakdown }
      end

      # Rails does not report GC time on process_action. When the payload does carry
      # it (some setups add it), use it; otherwise the component is nil and shows as
      # unavailable rather than as zero GC time.
      def gc_time_for(event)
        value = event.payload[:gc_runtime] || event.payload[:gc_time]
        value&.to_f
      end

      def measure(value, reason)
        return Measurement.unavailable(reason) if value.nil?

        Measurement.value(value.to_f)
      end

      def unavailable_metrics(why)
        {
          db_runtime_ms: Measurement.unavailable(why),
          view_runtime_ms: Measurement.unavailable(why)
        }
      end

      def reason
        return "track_time_breakdown is disabled" unless enabled?
        return "the time breakdown subscriber was not started" unless subscribed?

        "no process_action event was recorded for this request; the request did not reach a controller"
      end
    end
  end
end

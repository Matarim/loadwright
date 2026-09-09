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

      Breakdown = Struct.new(:total_ms, :db_ms, :view_ms, :gc_ms, :other_ms, :controller, :action, :spans,
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

      # Builds a breakdown from figures the pipeline already carries, rather than from a
      # notification. Used to aggregate an ENDPOINT's breakdown from its requests: the
      # subscriber is per-request and lives in whichever process ran the controller,
      # while this is arithmetic the harness can do over what came back.
      #
      # `other` stays a named residual. Middleware, authentication, controller Ruby, and
      # any outbound HTTP that was not blocked all live there, and a large `other` is a
      # real finding -- it is just not one this breakdown can attribute further.
      # THE TOP OFFENDERS INSIDE `other`, AND WHAT IS STILL UNNAMED.
      #
      # Both halves are the point. The named spans say what the application announced it
      # was doing; the remainder says how much of the residual nothing announced at all,
      # which on a serialisation-heavy endpoint is usually the majority and is exactly
      # the pure Ruby a notification cannot see.
      #
      # SPANS MAY NEST -- a cache read containing a query, a serializer containing a
      # cache read -- so they are reported as observed durations and NOT as a partition.
      # The remainder is therefore computed against the largest single span rather than
      # against their sum, because summing overlapping spans can exceed `other` and a
      # negative remainder would be nonsense. Where even that exceeds `other`, the
      # remainder is unavailable rather than invented.
      Span = Struct.new(:name, :ms, :count, :share, keyword_init: true) do
        def per_call_ms = count.to_i.positive? ? ms / count : nil

        def to_h
          { name: name, ms: ms&.round(3), count: count, share: share&.round(4),
            per_call_ms: per_call_ms&.round(3) }.compact
        end
      end

      def self.top_spans(spans, other_ms, limit:, requests: 1)
        return [] if other_ms.nil? || other_ms.to_f <= 0 || Hash(spans).empty?

        divisor = [requests, 1].max
        Hash(spans)
          .map { |name, span| [name, span[:ms].to_f / divisor, span[:count].to_i] }
          .reject { |_, ms, _| ms <= 0 }
          .sort_by { |_, ms, _| -ms }
          .first(limit)
          .map { |name, ms, count| Span.new(name: name, ms: ms, count: count, share: ms / other_ms.to_f) }
      end

      # nil rather than a number when the spans overlap enough to exceed the residual:
      # saying "we cannot apportion this" is honest, and a negative or zero-clamped
      # remainder would read as "all accounted for", which is the opposite of true.
      def self.unattributed_ms(top, other_ms)
        return nil if other_ms.nil?
        largest = top.map(&:ms).max
        return other_ms.to_f if largest.nil?
        return nil if largest > other_ms.to_f

        other_ms.to_f - largest
      end

      def self.from_totals(total_ms:, db_ms: nil, view_ms: nil, gc_ms: nil, controller: nil, action: nil)
        return nil if total_ms.nil?

        accounted = [db_ms, view_ms, gc_ms].compact.sum
        Breakdown.new(
          total_ms: total_ms, db_ms: db_ms, view_ms: view_ms, gc_ms: gc_ms,
          # Clamped at zero for the same reason #record clamps it: the components are
          # measured independently and can sum to slightly more than the total on a fast
          # request, and a negative residual is nonsense in a report.
          other_ms: [total_ms - accounted, 0.0].max,
          controller: controller, action: action
        )
      end

      def initialize(config: Loadwright.configuration)
        @config = config
        @breakdowns = {}
        # request id -> { event name => { ms:, count: } }, accumulated while the request
        # runs and folded into its Breakdown when process_action closes it.
        @spans = {}
        @mutex = Mutex.new
        @subscriber = nil
        @span_subscriber = nil
      end

      def enabled? = @config.track_time_breakdown

      def start!
        return self unless enabled?
        return self if @subscriber

        require "active_support/notifications"

        @subscriber = ::ActiveSupport::Notifications.subscribe(EVENT) do |*args|
          record(::ActiveSupport::Notifications::Event.new(*args))
        end
        subscribe_spans!

        self
      end

      # WHAT ELSE THE APPLICATION SAID IT WAS DOING.
      #
      # `other` is a residual, and on a serialisation-heavy endpoint it is most of the
      # request -- 85% in one real case. A residual names nothing, so a reader with a
      # slow endpoint and a clean query count has been told where the time is NOT and
      # left to guess where it is.
      #
      # Rails and its neighbours already announce a great deal of that time through
      # ActiveSupport::Notifications, and so does the application's own custom
      # instrumentation. Nothing read any of it. Object instantiation, cache reads,
      # serializer runs, mailer delivery, job enqueues, HTTP clients that instrument
      # themselves -- all of it arrives here for free and all of it landed in `other`
      # anonymously.
      #
      # THE FIVE-ARGUMENT BLOCK, deliberately. The Event object form allocates one
      # object per event, and this subscriber sees EVERY event in the process; on a load
      # run that allocation is itself a measurable cost, which would distort the very
      # number being attributed.
      def subscribe_spans!
        return unless @config.respond_to?(:attribute_other_time) && @config.attribute_other_time

        @span_subscriber = ::ActiveSupport::Notifications.subscribe(/.*/) do |name, start, finish, _id, _p|
          record_span(name, (finish - start) * 1000.0)
        end
      end

      def stop!
        ::ActiveSupport::Notifications.unsubscribe(@subscriber) if @subscriber
        ::ActiveSupport::Notifications.unsubscribe(@span_subscriber) if @span_subscriber
        @subscriber = nil
        @span_subscriber = nil
        self
      end

      def subscribed? = !@subscriber.nil?

      def for_request(request_id) = @mutex.synchronize { @breakdowns[request_id] }

      # THE SPANS ARE NOT THE CONTROLLER'S TO GATE. They used to be readable only off a
      # folded Breakdown, and a Breakdown exists only where `process_action` fired --
      # so on a Grape or Rack mount, or any request that errored before its action, the
      # spans were collected correctly and then stranded. That is the whole feature
      # silently producing nothing on exactly the stacks whose residual is largest,
      # with no warning and no unavailable-reason: the reader concludes there is
      # nothing inside `other` when nothing was ever read.
      #
      # AS::N events do not need a controller. Neither does this.
      def spans_for(request_id)
        @mutex.synchronize do
          breakdown = @breakdowns[request_id]
          spans = breakdown && breakdown.spans
          spans.nil? || spans.empty? ? (@spans[request_id] || {}) : spans
        end
      end

      # BOTH MAPS. `forget` cleared the breakdown and left the span buffer, so every
      # request on a stack that never folds one leaked its spans for the length of the
      # run -- ~52k orphaned hashes on an 87-endpoint run, invisible and growing.
      def forget(request_id)
        @mutex.synchronize do
          @spans.delete(request_id)
          @breakdowns.delete(request_id)
        end
      end

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

      # ALREADY COUNTED SOMEWHERE ELSE. The wrapper IS the total; SQL is `db`; the
      # render events are `view`. Attributing them again would let the parts exceed the
      # whole, which is the one thing a breakdown must never do.
      ACCOUNTED_EVENTS = [
        "process_action.action_controller",
        "sql.active_record",
        "render_template.action_view",
        "render_partial.action_view",
        "render_collection.action_view",
        "render_layout.action_view"
      ].freeze

      # Events that fire per run rather than per request, or that describe the harness
      # rather than the application.
      IGNORED_SPAN_PREFIXES = %w[loadwright. !].freeze

      # LIFECYCLE MARKERS, NOT WORK. `start_processing` is the "a request began" signal
      # that Rails fires immediately before the action; its duration is the cost of
      # announcing itself and nothing else. It appears on every ActionController request,
      # so left in it takes a permanent seat in the top offenders while naming no work at
      # all -- and a 0.0ms row in a list of the largest spans reads as a broken list.
      MARKER_EVENTS = ["start_processing.action_controller"].freeze

      private

      def record_span(name, duration_ms)
        return if ACCOUNTED_EVENTS.include?(name) || MARKER_EVENTS.include?(name)
        return if IGNORED_SPAN_PREFIXES.any? { |prefix| name.start_with?(prefix) }

        request_id = Instrumentation::CurrentRequest.id
        return if request_id.nil?

        @mutex.synchronize do
          bucket = (@spans[request_id] ||= {})
          span = (bucket[name] ||= { ms: 0.0, count: 0 })
          span[:ms] += duration_ms
          span[:count] += 1
        end
      end

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

        # The spans were accumulated as the request ran, so they are collected here and
        # cleared -- the request is over and nothing else will add to them.
        spans = @mutex.synchronize { @spans.delete(request_id) } || {}

        breakdown = Breakdown.new(
          total_ms: total, db_ms: db&.to_f, view_ms: view&.to_f, gc_ms: gc,
          other_ms: other, controller: payload[:controller], action: payload[:action],
          spans: spans
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

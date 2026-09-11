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
      # `calls` IS THE RUN TOTAL AND `ms` IS PER REQUEST, so per-call cost must divide one
      # by the other in the SAME units. It did not: `ms` was divided by the requests that
      # produced it and `calls` was left as the raw total, so the per-call figure came out
      # understated by exactly the request count -- 600 requests reported a 65ms once-per-
      # request calculation as 600 calls at 0.108ms.
      #
      # AND IT INVERTED THE DIAGNOSIS, which is why it mattered more than its size. The
      # whole point of this column is that 40ms over 300 calls and 40ms over one are
      # different problems: the first wants a loop hoisted, the second wants caching or a
      # better algorithm. Reporting one expensive call as hundreds of cheap ones sends the
      # reader to look for the wrong thing, in a column they have no independent way to
      # check. It was caught only because that application logs the same quantity itself.
      Span = Struct.new(:name, :ms, :calls, :calls_per_request, :share, keyword_init: true) do
        def per_call_ms = calls_per_request.to_f.positive? ? ms / calls_per_request : nil

        def to_h
          { name: name, ms: ms&.round(3), calls: calls,
            calls_per_request: calls_per_request&.round(2), share: share&.round(4),
            per_call_ms: per_call_ms&.round(3) }.compact
        end
      end

      # THE SHARE IS OF THE REQUEST, NOT OF `other`, and that is not a presentation
      # choice. A span is guaranteed to nest inside the request; it is NOT guaranteed to
      # nest inside the residual, because the residual excludes db and view time and the
      # span does not. An instrumented method that queries -- which is most of what an
      # application chooses to instrument -- contains its own SQL, so its duration
      # routinely exceeds `other` outright. Measured against the residual that printed a
      # share of 691%, which is a number that tells a reader the tool is broken, on
      # exactly the endpoint they were told to look at.
      def self.top_spans(spans, other_ms, limit:, requests: 1, total_ms: nil)
        return [] if other_ms.nil? || other_ms.to_f <= 0 || Hash(spans).empty?

        divisor = [requests, 1].max
        basis = total_ms.to_f.positive? ? total_ms.to_f : nil
        Hash(spans)
          .map { |name, span| [name, span[:ms].to_f / divisor, span[:count].to_i] }
          .reject { |_, ms, _| ms <= 0 }
          .sort_by { |_, ms, _| -ms }
          .first(limit)
          .map do |name, ms, calls|
            Span.new(name: name, ms: ms, calls: calls, calls_per_request: calls.to_f / divisor,
                     share: basis && (ms / basis))
          end
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

      # AND WHY IT COULD NOT BE COMPUTED, which is the half that stops "unavailable"
      # reading as a shrug. There is one dominant cause and it is not exotic: an
      # instrumented block that issues queries contains its own SQL, and `other` excludes
      # SQL -- so the span is longer than the residual it is being shown inside. That is
      # the normal shape for anything an application chooses to instrument, not an edge
      # case, and a reader who is not told this concludes the numbers disagree.
      def self.unattributed_reason(top, other_ms)
        return nil if other_ms.nil? || top.empty?
        largest = top.max_by(&:ms)
        return nil unless largest && largest.ms > other_ms.to_f

        "the largest span (`#{largest.name}`, #{largest.ms.round(2)}ms) is longer than the residual " \
          "itself, so the residual cannot be apportioned. Two things cause that, and the second is " \
          "more likely on a span this size: the instrumented block contains work already counted as " \
          "database or view time (its queries are inside the span and outside `other`), or the span " \
          "IS the request rather than a part of it -- a framework's own endpoint wrapper, which sits " \
          "at 90-100% of every request. If it is the latter, name it in `accounted_span_events` and " \
          "it will stop competing with your own instrumentation. It is not a disagreement between " \
          "the numbers."
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
        # request id -> { event name => merged span }, for the events that ARE the request
        # rather than a part of it. Kept out of the ranking and reported in one sentence.
        @wrappers = {}
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
          record_span(name, start, finish)
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
          spans = @spans[request_id] if spans.nil? || spans.empty?
          project(spans)
        end
      end

      # THE OUTER LAYER, NAMED. A mounted framework's wrapper span covers the whole
      # request, so it can never be one of the largest things INSIDE the request -- but
      # its absence from the table is not the same as its absence from the run. "The
      # handler body took 98% of the request and nothing inside it announced itself" tells
      # a reader where to put an `instrument` call; "nothing announced itself" tells them
      # the tool saw nothing, which is not what happened.
      def wrapper_for(request_id)
        @mutex.synchronize do
          projected = project(@wrappers[request_id])
          next nil if projected.empty?

          name, span = projected.max_by { |_, value| value[:ms] }
          { name: name, ms: span[:ms], count: span[:count] }
        end
      end

      # The merged intervals are working state and never leave this object: nothing
      # downstream can do anything with them, they would cross the collection endpoint as
      # noise, and they are the one part of a span that is not a measurement.
      def project(spans)
        Hash(spans).to_h { |name, span| [name, { ms: span[:ms], count: span[:count] }] }
      end

      # BOTH MAPS. `forget` cleared the breakdown and left the span buffer, so every
      # request on a stack that never folds one leaked its spans for the length of the
      # run -- ~52k orphaned hashes on an 87-endpoint run, invisible and growing.
      def forget(request_id)
        @mutex.synchronize do
          @spans.delete(request_id)
          @wrappers.delete(request_id)
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
        "render_layout.action_view",
        # THE SAME ARGUMENT, FOR A MOUNTED FRAMEWORK. Rails' `process_action` is excluded
        # because it IS the request; Grape's `endpoint_run` is exactly that event under
        # another name, and `endpoint_render` is the analogue of the render events above.
        # Left in, they sat at 93% of every request, took two of the three ranking slots
        # on 63 endpoints, and made the unattributed remainder unavailable everywhere --
        # a span the size of the request is always larger than the residual inside it. The
        # application's own instrumented calculation reached a table once in a full run.
        #
        # Worth knowing WHY this is not a heuristic on share: a genuine single span at 95%
        # of a request is the exact case this feature exists to surface, so "large means
        # wrapper" would hide the finding. Only the name distinguishes them.
        "endpoint_run.grape",
        "endpoint_render.grape",
        "endpoint_run_filters.grape",
        "endpoint_run_validators.grape",
        "format_response.grape",
        # EVERY MIDDLEWARE WRAPS THE REST OF THE STACK, and Rails fires this once per
        # middleware under the same event name -- so the outermost one is the whole
        # request and the rest nest inside it. It is also the clearest case for merging
        # intervals rather than summing them, since summed it reported multiples of the
        # request. Note that Rails only installs this instrumentation when something is
        # subscribed to it, and subscribing to everything is what this class does: the
        # tool was turning on the very events that then masked the application's own.
        "process_middleware.action_dispatch",
        # A GraphQL request under the ActiveSupport notifications trace. The multiplex is
        # the whole HTTP request and the query is the whole operation; per-FIELD events
        # (`graphql.execute_field`) are parts and stay rankable, which is where a
        # resolver problem actually shows up.
        "graphql.execute_multiplex",
        "graphql.execute_query",
        "graphql.execute_query_lazy"
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

      def record_span(name, start, finish)
        return if MARKER_EVENTS.include?(name)
        return if IGNORED_SPAN_PREFIXES.any? { |prefix| name.start_with?(prefix) }

        request_id = Instrumentation::CurrentRequest.id
        return if request_id.nil?

        # A WRAPPER IS KEPT, NOT DISCARDED. It cannot compete for a ranking slot -- it is
        # the request, not a part of it -- but knowing that the handler body covered 98%
        # of the request and that nothing inside it announced itself is a different and
        # more useful statement than "nothing announced itself". See #wrapper_for.
        store = accounted?(name) ? @wrappers : @spans

        @mutex.synchronize do
          bucket = (store[request_id] ||= {})
          absorb_span(bucket, name, start, finish)
        end
      end

      def accounted?(name)
        ACCOUNTED_EVENTS.include?(name) || configured_accounted_events.include?(name)
      end

      # WALL TIME IN AN EVENT, NOT THE SUM OF ITS DURATIONS, and the difference is not
      # pedantic. An event nested inside ITSELF gets counted once per level: Rails fires
      # `process_middleware.action_dispatch` once per middleware, each wrapping the rest
      # of the stack, and a cache read around a cache read or a serializer that recurses
      # does the same. Summed, three nested levels of a 50ms event reported 159.9ms and a
      # share of 307% of the request -- the same species as the 691% share that measuring
      # against the residual used to produce, and just as sure a signal to a reader that
      # the tool cannot count.
      #
      # So the intervals are UNIONED. Notifications arrive in finish order, so an event
      # containing earlier ones arrives after them: the trailing intervals it covers are
      # dropped and it replaces them, which is O(1) amortised on a path that sees every
      # event in the process. `count` still counts occurrences -- three nested middlewares
      # really are three calls -- so the per-call figure stays truthful while the total
      # stops double-counting.
      def absorb_span(bucket, name, start, finish)
        span = (bucket[name] ||= { ms: 0.0, count: 0, intervals: [] })
        span[:count] += 1

        from = start.to_f
        to = finish.to_f
        intervals = span[:intervals]

        while (last = intervals.last) && last[0] >= from
          span[:ms] -= (last[1] - last[0]) * 1000.0
          intervals.pop
        end

        if (last = intervals.last) && from < last[1]
          span[:ms] -= (last[1] - last[0]) * 1000.0
          intervals.pop
          from = last[0]
          to = [to, last[1]].max
        end

        intervals << [from, to]
        span[:ms] += (to - from) * 1000.0
      end

      # Read once per run rather than per event: this method is on the path of EVERY
      # notification in the process, and a config lookup there is not free.
      def configured_accounted_events
        @configured_accounted_events ||=
          if @config.respond_to?(:accounted_span_events)
            Array(@config.accounted_span_events).map(&:to_s).freeze
          else
            [].freeze
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

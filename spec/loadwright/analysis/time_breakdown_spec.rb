# frozen_string_literal: true

RSpec.describe Loadwright::Analysis::TimeBreakdown do
  let(:config) { Loadwright::Configuration.new }

  subject(:breakdown) { described_class.new(config: config) }

  after { breakdown.stop! }

  # Emits a real process_action event, since what is under test is the routing and
  # the arithmetic, not Rails.
  def emit(request_id:, total: 100.0, db: nil, view: nil, gc: nil, controller: "PostsController",
           action: "index")
    Loadwright::Instrumentation::CurrentRequest.with(request_id) do
      ActiveSupport::Notifications.instrument(
        described_class::EVENT,
        db_runtime: db, view_runtime: view, gc_runtime: gc, controller: controller, action: action
      ) { sleep(total / 1000.0) }
    end
  end

  describe "the split" do
    before { breakdown.start! }

    it "records db, view and the residual" do
      emit(request_id: "a", total: 100, db: 20.0, view: 60.0)

      result = breakdown.for_request("a")
      expect(result.db_ms).to eq(20.0)
      expect(result.view_ms).to eq(60.0)
      expect(result.other_ms).to be_within(15).of(20.0)
      expect(result.total_ms).to be >= 100
    end

    # THE FINDING THIS EXISTS FOR. An endpoint at 400ms with 3 queries has no
    # query-count finding at all — so a query-focused tool has nothing to say, the
    # developer goes looking at SQL, finds nothing, and concludes the tool was
    # wrong. Naming view time as dominant is what redirects them to the serialiser.
    it "names view as dominant for a serialisation-bound endpoint" do
      emit(request_id: "a", total: 40, db: 4.0, view: 34.0)

      expect(breakdown.for_request("a").dominant).to eq(:view)
    end

    it "names db as dominant for a query-bound endpoint" do
      emit(request_id: "a", total: 40, db: 34.0, view: 2.0)

      expect(breakdown.for_request("a").dominant).to eq(:db)
    end

    # `other` is a named residual rather than an omission: middleware,
    # authentication and external HTTP live there, and a large `other` is a real
    # finding that this breakdown simply cannot attribute further.
    it "names other as dominant when the time is neither db nor view" do
      emit(request_id: "a", total: 60, db: 1.0, view: 1.0)

      expect(breakdown.for_request("a").dominant).to eq(:other)
    end

    it "reports each component's share of the total" do
      emit(request_id: "a", total: 20, db: 5.0, view: 10.0)

      result = breakdown.for_request("a")
      expect(result.share(:view)).to be_within(0.2).of(0.5)
    end

    # db_runtime and view_runtime are measured independently and can sum to slightly
    # more than the total on a fast request. A negative residual would be nonsense
    # in a report.
    it "clamps the residual at zero rather than reporting negative time" do
      emit(request_id: "a", total: 1, db: 50.0, view: 50.0)

      expect(breakdown.for_request("a").other_ms).to eq(0.0)
    end

    it "records the controller and action, so a finding names real code" do
      emit(request_id: "a", db: 1.0, controller: "Api::V1::AuthorsController", action: "index")

      expect(breakdown.for_request("a").to_h)
        .to include(controller: "Api::V1::AuthorsController", action: "index")
    end
  end

  # Same reason QueryTracker subscribes once: AS::N subscribers are process-global,
  # so a per-request subscriber receives every concurrent request's events.
  describe "attribution under concurrency" do
    before { breakdown.start! }

    it "attributes each request's timing to that request" do
      gate = Queue.new
      timings = { "a" => 30.0, "b" => 10.0, "c" => 50.0 }

      threads = timings.map do |request_id, view|
        Thread.new do
          gate << request_id
          sleep 0.01 while gate.length < timings.size
          emit(request_id: request_id, total: 5, db: 1.0, view: view)
        end
      end
      threads.each(&:join)

      expect(timings.keys.to_h { |id| [id, breakdown.for_request(id).view_ms] }).to eq(timings)
    end

    it "drops an event with no request in scope rather than guessing an owner" do
      ActiveSupport::Notifications.instrument(described_class::EVENT, db_runtime: 5.0) { nil }

      expect(breakdown.to_h[:requests_measured]).to eq(0)
    end
  end

  describe "#metrics_for" do
    it "produces Measurements keyed to RequestMetrics' fields" do
      breakdown.start!
      emit(request_id: "a", db: 12.5, view: 30.0)

      metrics = breakdown.metrics_for("a")

      expect(metrics[:db_runtime_ms]).to eq(Loadwright::Measurement.value(12.5))
      expect(metrics[:view_runtime_ms]).to eq(Loadwright::Measurement.value(30.0))
    end

    # A request that never reached a controller has no view time — not zero view
    # time. Zero would read as "measured, and serialisation is free".
    it "reports unavailable with a reason when the request never reached a controller" do
      breakdown.start!

      metrics = breakdown.metrics_for("never-happened")

      expect(metrics[:view_runtime_ms]).to be_unavailable
      expect(metrics[:view_runtime_ms].reason).to include("did not reach a controller")
    end

    it "reports unavailable when Rails reported no view_runtime" do
      breakdown.start!
      emit(request_id: "a", db: 5.0, view: nil)

      expect(breakdown.metrics_for("a")[:view_runtime_ms]).to be_unavailable
    end

    it "reports unavailable with the config reason when the user turned it off" do
      config.track_time_breakdown = false
      breakdown.start!

      expect(breakdown.metrics_for("a")[:db_runtime_ms].reason)
        .to include("track_time_breakdown is disabled")
    end
  end

  describe "lifecycle" do
    it "subscribes once, so a double start cannot double-count" do
      breakdown.start!
      breakdown.start!
      emit(request_id: "a", db: 5.0)

      expect(breakdown.for_request("a").db_ms).to eq(5.0)
    end

    it "does not subscribe when disabled" do
      config.track_time_breakdown = false

      breakdown.start!

      expect(breakdown).not_to be_subscribed
    end

    it "stops attributing after stop!" do
      breakdown.start!
      breakdown.stop!

      emit(request_id: "a", db: 5.0)

      expect(breakdown.for_request("a")).to be_nil
    end

    it "releases a request's breakdown on forget" do
      breakdown.start!
      emit(request_id: "a", db: 5.0)

      breakdown.forget("a")

      expect(breakdown.for_request("a")).to be_nil
    end
  end

  # The real path, against the fixture app's genuinely serialisation-light and
  # query-heavy endpoints.
  describe "against the fixture app", :sample_app do
    it "reads Rails' own db_runtime for a real request" do
      require "action_dispatch/testing/integration"
      FactoryBot.create_list(:post, 5, :with_comments)
      breakdown.start!
      session = ActionDispatch::Integration::Session.new(sample_app)

      Loadwright::Instrumentation::CurrentRequest.with("real-1") do
        session.get "/api/v1/posts"
      end

      result = breakdown.for_request("real-1")
      expect(result).not_to be_nil
      expect(result.db_ms).to be > 0
      expect(result.controller).to eq("Api::V1::PostsController")
      expect(result.action).to eq("index")
    end
  end

  # `other` IS A RESIDUAL AND A RESIDUAL NAMES NOTHING. On a serialisation-heavy endpoint
  # it is most of the request, so a reader with a slow endpoint and a clean query count
  # has been told where the time is NOT and left to guess where it is. Rails and the
  # app's own instrumentation already announce much of it; nothing read any of it.
  describe ".top_spans" do
    let(:spans) do
      { "instantiation.active_record" => { ms: 40.0, count: 300 },
        "cache_read.active_support" => { ms: 12.0, count: 90 },
        "render.my_serializer" => { ms: 9.0, count: 1 },
        "tiny.event" => { ms: 0.5, count: 2 } }
    end

    it "names the largest spans, worst first" do
      top = described_class.top_spans(spans, 500.0, limit: 3)

      expect(top.map(&:name)).to eq(["instantiation.active_record", "cache_read.active_support",
                                     "render.my_serializer"])
    end

    # PER REQUEST, like every other figure in the breakdown. Spans are summed across a
    # cell's requests while `other_ms` is a median of single requests, so without
    # dividing, the top offender reads a hundred times larger than the residual it is
    # supposed to sit inside.
    it "divides by the requests that produced them" do
      top = described_class.top_spans(spans, 500.0, limit: 1, requests: 100)

      expect(top.first.ms).to be_within(0.001).of(0.4)
    end

    # One slow call and four hundred cheap ones have entirely different fixes.
    it "carries the call count and the per-call cost" do
      top = described_class.top_spans(spans, 500.0, limit: 3)
      serializer = top.find { |span| span.name == "render.my_serializer" }

      expect(serializer.calls).to eq(1)
      expect(serializer.per_call_ms).to be_within(0.001).of(9.0)
    end

    # THE COLUMN'S WHOLE PURPOSE IS TO SEPARATE ONE EXPENSIVE CALL FROM MANY CHEAP ONES,
    # and it did the opposite. `ms` was divided by the requests that produced it and the
    # call count was not, so a calculation running ONCE per request over 600 requests read
    # as 600 calls at a six-hundredth of its true cost -- understated by exactly the
    # request count, in the direction that sends the reader hunting for a loop to hoist
    # when the real answer is caching. Caught in the field only because that application
    # logged the same quantity itself.
    it "divides the call count by the requests too, so the per-call cost is per call" do
      one_call_per_request = { "calculate_payoff.my_app" => { ms: 38_916.0, count: 600 } }

      top = described_class.top_spans(one_call_per_request, 500.0, limit: 1, requests: 600,
                                      total_ms: 200.0)

      expect(top.first.calls_per_request).to be_within(0.001).of(1.0)
      expect(top.first.ms).to be_within(0.01).of(64.86)
      expect(top.first.per_call_ms).to be_within(0.01).of(64.86)
    end

    it "keeps the run total available beside the rate, so the arithmetic reconciles" do
      top = described_class.top_spans({ "a.b" => { ms: 600.0, count: 1200 } }, 500.0, limit: 1,
                                      requests: 600, total_ms: 200.0)

      expect(top.first.calls).to eq(1200)
      expect(top.first.calls_per_request).to be_within(0.001).of(2.0)
      expect(top.first.per_call_ms).to be_within(0.001).of(0.5)
    end

    # THE SHARE IS OF THE REQUEST, NOT OF THE RESIDUAL. A span nests inside the request
    # by construction; it does not nest inside `other`, which excludes db and view time
    # while the span includes them. An instrumented method that queries -- most of what
    # an application chooses to instrument -- therefore exceeds the residual outright,
    # and measured against it the share printed 691%: a number that tells a reader the
    # tool is broken, on the endpoint they were told to look at.
    it "computes the share against the whole request" do
      top = described_class.top_spans(spans, 40.0, limit: 1, total_ms: 400.0)

      expect(top.first.share).to be_within(0.0001).of(0.1)
    end

    it "has no share to state when the total is unknown, rather than inventing a basis" do
      top = described_class.top_spans(spans, 500.0, limit: 1)

      expect(top.first.share).to be_nil
    end

    it "says nothing when the application announced nothing" do
      expect(described_class.top_spans({}, 500.0, limit: 3)).to be_empty
    end

    it "says nothing when there is no residual to explain" do
      expect(described_class.top_spans(spans, 0.0, limit: 3)).to be_empty
    end
  end

  # THE UNATTRIBUTED HALF IS THE MORE IMPORTANT ONE. It is the pure Ruby that emits no
  # event at all, which on a serialisation problem is where the time actually is.
  describe ".unattributed_ms" do
    it "reports what nothing announced" do
      top = described_class.top_spans({ "a.b" => { ms: 40.0, count: 1 } }, 500.0, limit: 3)

      expect(described_class.unattributed_ms(top, 500.0)).to be_within(0.001).of(460.0)
    end

    it "is the whole residual when no span was announced" do
      expect(described_class.unattributed_ms([], 500.0)).to be_within(0.001).of(500.0)
    end

    # SPANS NEST -- a cache read containing a query, a serializer containing a cache
    # read -- so a span can legitimately exceed the residual it sits in. Saying "we
    # cannot apportion this" is honest; a zero-clamped remainder would read as "all
    # accounted for", which is the opposite of true.
    it "refuses to invent a remainder when a span exceeds the residual" do
      top = described_class.top_spans({ "a.b" => { ms: 900.0, count: 1 } }, 500.0, limit: 3)

      expect(described_class.unattributed_ms(top, 500.0)).to be_nil
    end
  end

  # THE QUESTION ROUND 13 ASKED AND COULD NOT ANSWER: how often is a span larger than
  # `other` itself? Often, and for one dominant reason -- an instrumented block that
  # issues queries contains its own SQL, which `other` excludes. The remainder is
  # correctly refused; refusing it WITHOUT saying why is the silence this round is about.
  describe ".unattributed_reason" do
    it "names the span and the reason when the residual cannot be apportioned" do
      top = described_class.top_spans({ "calculate.my_app" => { ms: 70.0, count: 1 } }, 10.0,
                                      limit: 3, total_ms: 100.0)

      reason = described_class.unattributed_reason(top, 10.0)

      expect(reason).to include("calculate.my_app")
      expect(reason).to include("database or view time")
    end

    it "is silent when the remainder was computable, since there is nothing to explain" do
      top = described_class.top_spans({ "calculate.my_app" => { ms: 4.0, count: 1 } }, 100.0,
                                      limit: 3, total_ms: 200.0)

      expect(described_class.unattributed_reason(top, 100.0)).to be_nil
    end
  end

  # ATTRIBUTING AN ALREADY-COUNTED EVENT WOULD LET THE PARTS EXCEED THE WHOLE, which is
  # the one thing a breakdown must never do.
  # WALL TIME IN AN EVENT, NOT THE SUM OF ITS DURATIONS. An event nested inside ITSELF
  # gets counted once per level: Rails fires `process_middleware.action_dispatch` once
  # per middleware, each wrapping the rest of the stack. Summed, three nested levels of a
  # 50ms event reported 159.9ms and a share of 307% of the request -- the same species as
  # the 691% share that measuring against the residual used to produce.
  describe "an event nested inside itself" do
    before do
      config.attribute_other_time = true
      breakdown.start!
    end

    # THE ARITHMETIC, WITH EXPLICIT INTERVALS. A `sleep`-based assertion on a merged
    # duration is an assertion about the machine's load, and this repo already carries
    # three clock-sensitive examples it regrets.
    def absorb(bucket, name, from, to)
      breakdown.send(:absorb_span, bucket, name, from, to)
    end

    it "counts the wall time once, not once per level" do
      bucket = {}

      absorb(bucket, "cache_read.active_support", 100.010, 100.020)
      absorb(bucket, "cache_read.active_support", 100.005, 100.030)
      absorb(bucket, "cache_read.active_support", 100.000, 100.040)

      expect(bucket["cache_read.active_support"][:ms]).to be_within(0.001).of(40.0)
      expect(bucket["cache_read.active_support"][:count]).to eq(3)
    end

    it "merges a partial overlap rather than counting the shared part twice" do
      bucket = {}

      absorb(bucket, "a.b", 100.000, 100.020)
      absorb(bucket, "a.b", 100.010, 100.030)

      expect(bucket["a.b"][:ms]).to be_within(0.001).of(30.0)
    end

    # The end-to-end version, asserted as a RELATIONSHIP rather than a figure: summed,
    # three nested levels of the same event would report about three times the wall
    # time, which no tolerance on a real clock can be mistaken for.
    it "reports far less than the sum of its levels, through real notifications" do
      Loadwright::Instrumentation::CurrentRequest.with("req-1") do
        ActiveSupport::Notifications.instrument("cache_read.active_support") do
          ActiveSupport::Notifications.instrument("cache_read.active_support") do
            ActiveSupport::Notifications.instrument("cache_read.active_support") { sleep 0.03 }
          end
        end
      end

      span = breakdown.spans_for("req-1")["cache_read.active_support"]
      expect(span[:ms]).to be >= 25.0
      expect(span[:ms]).to be < 70.0
    end

    # Three nested middlewares really are three calls, so the per-call figure stays
    # truthful even though the total stops double-counting.
    it "still counts the occurrences" do
      Loadwright::Instrumentation::CurrentRequest.with("req-1") do
        ActiveSupport::Notifications.instrument("cache_read.active_support") do
          ActiveSupport::Notifications.instrument("cache_read.active_support") { nil }
        end
      end

      expect(breakdown.spans_for("req-1")["cache_read.active_support"][:count]).to eq(2)
    end

    it "adds up sequential occurrences of the same event as before" do
      bucket = {}

      absorb(bucket, "cache_read.active_support", 100.000, 100.010)
      absorb(bucket, "cache_read.active_support", 100.020, 100.030)
      absorb(bucket, "cache_read.active_support", 100.040, 100.050)

      expect(bucket["cache_read.active_support"][:ms]).to be_within(0.001).of(30.0)
      expect(bucket["cache_read.active_support"][:count]).to eq(3)
    end

    # The merged intervals are working state: nothing downstream can use them, they
    # would cross the collection endpoint as noise, and they are the one part of a span
    # that is not a measurement.
    it "does not hand the intervals to anything downstream" do
      Loadwright::Instrumentation::CurrentRequest.with("req-1") do
        ActiveSupport::Notifications.instrument("cache_read.active_support") { nil }
      end

      expect(breakdown.spans_for("req-1")["cache_read.active_support"].keys).to contain_exactly(:ms, :count)
    end
  end

  # THE OUTER LAYER IS KEPT, NOT DISCARDED. A wrapper cannot compete for a ranking slot
  # -- it is the request, not a part of it -- but "the handler body was 98% of this and
  # nothing inside it announced itself" points a reader at where to put an `instrument`
  # call, where "nothing announced itself" reads as the tool having seen nothing.
  describe "#wrapper_for" do
    before do
      config.attribute_other_time = true
      breakdown.start!
    end

    it "names the wrapper and its cost, while keeping it out of the spans" do
      Loadwright::Instrumentation::CurrentRequest.with("req-1") do
        ActiveSupport::Notifications.instrument("endpoint_run.grape") do
          ActiveSupport::Notifications.instrument("instantiation.active_record") { sleep 0.01 }
        end
      end

      expect(breakdown.spans_for("req-1").keys).to eq(["instantiation.active_record"])
      expect(breakdown.wrapper_for("req-1")[:name]).to eq("endpoint_run.grape")
      expect(breakdown.wrapper_for("req-1")[:ms]).to be > 0
    end

    it "is nil on a stack with no wrapper, rather than inventing one" do
      Loadwright::Instrumentation::CurrentRequest.with("req-1") do
        ActiveSupport::Notifications.instrument("calculate.my_app") { nil }
      end

      expect(breakdown.wrapper_for("req-1")).to be_nil
    end

    it "is released with the request" do
      Loadwright::Instrumentation::CurrentRequest.with("req-1") do
        ActiveSupport::Notifications.instrument("endpoint_run.grape") { nil }
      end

      breakdown.forget("req-1")

      expect(breakdown.wrapper_for("req-1")).to be_nil
    end
  end

  describe "which events are eligible at all" do
    it "excludes the wrapper, the queries and the renders" do
      expect(described_class::ACCOUNTED_EVENTS)
        .to include("process_action.action_controller", "sql.active_record",
                    "render_template.action_view")
    end

    # A MOUNTED FRAMEWORK'S WRAPPER IS THE SAME EVENT UNDER ANOTHER NAME. Left in, it sat
    # at 93% of every request across 63 endpoints, took two of three ranking slots, and
    # made the unattributed remainder unavailable everywhere -- a span the size of the
    # request is always larger than the residual inside it. The application's own
    # instrumented calculation reached a table once in a full run.
    it "excludes a mounted framework's endpoint wrapper and renderer" do
      expect(described_class::ACCOUNTED_EVENTS)
        .to include("endpoint_run.grape", "endpoint_render.grape")
    end

    # EVERY MIDDLEWARE WRAPS THE REST OF THE STACK, under one event name, so the
    # outermost is the whole request. Rails only installs this instrumentation when
    # something is subscribed to it -- and subscribing to everything is what this class
    # does, so the tool was switching on the events that then masked the application's.
    it "excludes the middleware and GraphQL wrappers" do
      expect(described_class::ACCOUNTED_EVENTS)
        .to include("process_middleware.action_dispatch", "graphql.execute_multiplex",
                    "graphql.execute_query")
    end

    # Per-FIELD events are parts of a GraphQL request, not the request, and a resolver
    # problem is exactly what they surface.
    it "keeps GraphQL's per-field events rankable" do
      expect(described_class::ACCOUNTED_EVENTS).not_to include("graphql.execute_field")
    end

    it "excludes whatever else the user named, for a framework this gem does not know" do
      config.attribute_other_time = true
      config.accounted_span_events = ["endpoint_run.some_framework"]
      breakdown.start!

      Loadwright::Instrumentation::CurrentRequest.with("req-1") do
        ActiveSupport::Notifications.instrument("endpoint_run.some_framework") { nil }
        ActiveSupport::Notifications.instrument("calculate.my_app") { nil }
      end

      expect(breakdown.spans_for("req-1").keys).to eq(["calculate.my_app"])
    end

    # MATCHED BY NAME, NEVER BY SIZE. A genuine single span at 95% of a request is the
    # case this whole feature exists to surface, so a "large means wrapper" heuristic
    # would hide the finding it is supposed to find.
    it "keeps a large application span, which is the finding rather than the noise" do
      config.attribute_other_time = true
      breakdown.start!

      Loadwright::Instrumentation::CurrentRequest.with("req-2") do
        ActiveSupport::Notifications.instrument("serialize.my_app") { sleep 0.01 }
      end

      expect(breakdown.spans_for("req-2").keys).to eq(["serialize.my_app"])
    end
  end

  # THE STACK THAT NEVER EMITS process_action. A Grape or Rack mount, or any request
  # that errors before its action, produces no controller event -- and the spans used to
  # be readable only off the Breakdown that event folds. They were collected correctly
  # and then stranded, so the whole attribution said nothing on exactly the mounts whose
  # residual is largest, with no warning and no unavailable-reason.
  describe "#spans_for on a request that never reached a controller" do
    before do
      config.attribute_other_time = true
      breakdown.start!
    end

    def emit_spans(request_id)
      Loadwright::Instrumentation::CurrentRequest.with(request_id) do
        ActiveSupport::Notifications.instrument("calculate.my_app") { nil }
        ActiveSupport::Notifications.instrument("instantiation.active_record") { nil }
      end
    end

    it "returns the spans even though no breakdown exists" do
      emit_spans("grape-1")

      expect(breakdown.for_request("grape-1")).to be_nil
      expect(breakdown.spans_for("grape-1").keys).to include("calculate.my_app")
    end

    it "still returns the folded spans when the controller event did fire" do
      Loadwright::Instrumentation::CurrentRequest.with("rails-1") do
        ActiveSupport::Notifications.instrument("calculate.my_app") { nil }
        ActiveSupport::Notifications.instrument(described_class::EVENT, db_runtime: 1.0) { nil }
      end

      expect(breakdown.spans_for("rails-1").keys).to include("calculate.my_app")
    end

    # A LIFECYCLE MARKER IS NOT WORK. `start_processing` fires on every
    # ActionController request and its duration is the cost of announcing itself, so
    # left in it holds a permanent seat in the top offenders while naming nothing --
    # observed on a real run as a 0.0ms row in a list of the largest spans.
    it "ignores the request-started marker" do
      Loadwright::Instrumentation::CurrentRequest.with("rails-2") do
        ActiveSupport::Notifications.instrument("start_processing.action_controller") { nil }
        ActiveSupport::Notifications.instrument("calculate.my_app") { nil }
      end

      expect(breakdown.spans_for("rails-2").keys).to eq(["calculate.my_app"])
    end

    it "keeps requests apart" do
      emit_spans("grape-1")

      expect(breakdown.spans_for("grape-2")).to be_empty
    end

    # THE LEAK THAT RODE ALONG WITH THE GATE. `forget` cleared the breakdown map and
    # left the span buffer, so on such a stack every request's spans were retained for
    # the length of the run -- tens of thousands of unreachable hashes on a full run.
    it "releases the span buffer on forget" do
      10.times { |i| emit_spans("grape-#{i}") }

      10.times { |i| breakdown.forget("grape-#{i}") }

      expect(breakdown.instance_variable_get(:@spans)).to be_empty
    end
  end
end

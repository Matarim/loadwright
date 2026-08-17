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
end

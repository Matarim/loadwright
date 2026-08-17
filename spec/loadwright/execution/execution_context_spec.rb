# frozen_string_literal: true

RSpec.describe Loadwright::Execution::ExecutionContext do
  let(:config) { Loadwright::Configuration.new }

  def context(collector:, transport: nil, clock: nil)
    described_class.new(
      config: config,
      transport: transport || Loadwright::Execution::Transport::Null.new(config: config),
      collector: collector,
      clock: clock
    )
  end

  describe "capability derivation" do
    # The invariant the whole layer is arranged around: the SAME transport with
    # different collectors yields different capability. A regression that re-keys
    # capability off execution_mode fails here.
    it "derives capability from the (transport, collector) pair, not from the mode" do
      instrumented = context(collector: ExecutionHelpers::ScriptedCollector.new(config: config, name: :middleware),
                             transport: Loadwright::Execution::Transport::Http.new(config: config))
      degraded = context(collector: Loadwright::Execution::Collector::External.new(config: config),
                         transport: Loadwright::Execution::Transport::Http.new(config: config))

      expect(instrumented.capability_profile).to be_available(:queries_per_returned_record)
      expect(degraded.capability_profile).to be_unavailable(:queries_per_returned_record)
    end

    it "suppresses concurrency findings for the in-process transport rather than fabricating them" do
      profile = context(collector: ExecutionHelpers::ScriptedCollector.new(config: config),
                        transport: Loadwright::Execution::Transport::InProcess.new(config: config))
                .capability_profile

      expect(profile).to be_unavailable(:latency_under_concurrency)
      expect(profile).to be_unavailable(:connection_pool_exhaustion)
      expect(profile.reason_for(:latency_under_concurrency)).to include("execution_mode = :http")
    end
  end

  describe "#issue" do
    it "returns the response, the metrics, and the epoch they belong to" do
      subject = context(collector: ExecutionHelpers::ScriptedCollector.new(config: config, metrics: { query_count: 7 }))
      request = build_request

      outcome = subject.issue(request)

      expect(outcome.response.status).to eq(200)
      expect(outcome.metrics.query_count).to eq(Loadwright::Measurement.value(7))
      expect(outcome.capability_epoch).to eq(0)
    end

    # begin_request marks this thread as belonging to a request id, and normally
    # collect clears it. If anything in between raises, the id stays set and the NEXT
    # request's queries are attributed to the previous one — the endpoint that errored
    # gets credited with the following endpoint's N+1. A wrong number, not a missing
    # one, and nothing downstream could detect it.
    it "clears the request marker even when collection raises" do
      exploding = Class.new(ExecutionHelpers::ScriptedCollector) do
        def collect(*, **) = raise "collector blew up"
      end.new(config: config)
      subject = context(collector: exploding)

      expect { subject.issue(build_request) }.to raise_error("collector blew up")
      expect(Loadwright::Instrumentation::CurrentRequest.id).to be_nil
    end

    it "clears the request marker on the happy path too" do
      subject = context(collector: Loadwright::Execution::Collector::Direct.new(config: config))
      subject.start!

      subject.issue(build_request)

      expect(Loadwright::Instrumentation::CurrentRequest.id).to be_nil
      subject.stop!
    end

    it "opens the collector's request before the transport issues it" do
      collector = ExecutionHelpers::ScriptedCollector.new(config: config)
      subject = context(collector: collector)
      request = build_request

      subject.issue(request)

      expect(collector.begun).to eq([request.request_id])
    end
  end

  describe "mid-run capability degradation" do
    # execution-modes.md: "a spec proving a mid-run capability downgrade opens a
    # new epoch and that results collected before it retain their original
    # attribution."
    #
    # This is the property that stops a report attributing full-capability
    # findings to a window in which collection had already silently failed.
    it "opens a new epoch and leaves earlier results attributed to the old one" do
      collector = ExecutionHelpers::ScriptedCollector.new(config: config, degrade_after: 2)
      subject = context(collector: collector)

      epochs = 4.times.map { subject.issue(build_request).capability_epoch }

      expect(epochs).to eq([0, 0, 0, 1])
      expect(subject.capabilities).to be_degraded
      expect(subject.capabilities.lost_signals).to include(:n_plus_one_slope, :queries_per_returned_record)
    end

    it "keeps the pre-degradation profile readable, so old results stay interpretable" do
      collector = ExecutionHelpers::ScriptedCollector.new(config: config, degrade_after: 1)
      subject = context(collector: collector)

      2.times { subject.issue(build_request) }
      subject.issue(build_request)

      expect(subject.capabilities.profile_at(0)).to be_available(:n_plus_one_slope)
      expect(subject.capabilities.profile_at(1)).to be_unavailable(:n_plus_one_slope)
    end

    # A middleware failing on every request must produce one epoch, not one per
    # request — otherwise a degraded run's timeline is a wall of noise.
    it "opens one epoch for a repeating failure, not one per request" do
      collector = ExecutionHelpers::ScriptedCollector.new(config: config, degrade_after: 0)
      subject = context(collector: collector)

      10.times { subject.issue(build_request) }

      expect(subject.capabilities.epochs.length).to eq(2)
    end
  end

  describe ".build" do
    it "gives a dry run a Null transport that refuses to issue anything" do
      subject = described_class.build(config: config, dry_run: true)

      expect(subject.transport.name).to eq(:null)
      expect { subject.issue(build_request) }
        .to raise_error(Loadwright::Execution::Transport::Base::DryRunViolation)
    end

    it "pairs :in_process with the direct collector" do
      config.execution_mode = :in_process

      subject = described_class.build(config: config)

      expect([subject.transport.name, subject.collector.collector_name]).to eq(%i[in_process direct])
    end

    it "refuses an unknown execution mode" do
      config.execution_mode = :telepathy

      expect { described_class.build(config: config) }
        .to raise_error(Loadwright::ConfigurationError, /unknown execution_mode/)
    end
  end

  describe "#to_h" do
    it "records the pairing and the capability timeline for report metadata" do
      subject = context(collector: ExecutionHelpers::ScriptedCollector.new(config: config, degrade_after: 0))
      subject.issue(build_request)
      subject.issue(build_request)

      audit = subject.to_h

      expect(audit).to include(transport: :null, collector: :direct)
      expect(audit[:capabilities][:degraded]).to be(true)
      expect(audit[:capabilities][:epochs].length).to eq(2)
      expect(audit[:capabilities][:epochs].last[:cause]).to include("scripted mid-run collection failure")
    end
  end
end

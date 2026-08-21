# frozen_string_literal: true

RSpec.describe Loadwright::Execution::Collector::Base do
  let(:config) { Loadwright::Configuration.new }

  it "requires subclasses to name themselves, since CapabilityProfile keys on it" do
    expect { described_class.new(config: config).collector_name }
      .to raise_error(NotImplementedError, /#collector_name/)
  end

  it "requires subclasses to implement #collect" do
    collector = Class.new(described_class) { def collector_name = :fake }.new(config: config)

    expect { collector.collect(build_request, nil) }.to raise_error(NotImplementedError, /#collect/)
  end

  describe "degradation" do
    subject(:collector) do
      Class.new(described_class) do
        def collector_name = :fake

        def fail!(reason) = degrade!(%i[n_plus_one_slope], reason)
      end.new(config: config)
    end

    it "starts undegraded" do
      expect(collector).not_to be_degraded
      expect(collector.degradation).to be_nil
    end

    # A middleware that fails on every request must not overwrite the original
    # cause with the hundredth instance of it — the first failure is the one that
    # explains the run.
    it "records only the first degradation" do
      collector.fail!("middleware stopped answering")
      collector.fail!("and again")
      collector.fail!("and again")

      expect(collector.degradation[:reason]).to eq("middleware stopped answering")
    end
  end

  describe "side-effect volume" do
    # A collector that measures the delta the real path measures: begin_request takes
    # the baseline, collect subtracts it.
    def counting_collector
      Class.new(described_class) do
        def collector_name = :fake
        def collect(request, response, capability_epoch: 0) = response_derived(response, request)
      end.new(config: config)
    end

    # A mutable mail outbox, so a "delivery" can happen BETWEEN the baseline and the
    # collection, which is what a request sending mail actually looks like.
    def stub_outbox(entries)
      stub_const("ActionMailer::Base", Class.new { def self.deliveries = @deliveries ||= [] })
      ActionMailer::Base.deliveries.concat(entries)
    end

    # Containment forces mail and jobs to :test adapters, which RECORD rather than
    # perform. That turns suppression into a measurement: a request enqueuing 200
    # jobs is a finding, and dropping the jobs silently would lose it.
    it "counts the mail one request delivered" do
      stub_outbox([:already_sent_before_the_run])
      collector = counting_collector
      request = build_request

      collector.begin_request(request)
      ActionMailer::Base.deliveries.concat(%i[one two three])

      expect(collector.collect(request, nil)[:mail_deliveries]).to eq(Loadwright::Measurement.value(3))
    end

    # THE NUMBER THAT WOULD OTHERWISE RISE WITH NOTHING BUT TIME. The test adapters
    # accumulate across the whole run, so reporting the raw total per request shows
    # request 500 enqueuing 500 jobs and request 1 enqueuing one.
    it "reports a delta, not the total the adapter has accumulated all run" do
      adapter = Class.new { def enqueued_jobs = @jobs ||= [] }.new
      stub_const("ActiveJob::Base", Class.new).tap { |k| k.define_singleton_method(:queue_adapter) { adapter } }
      adapter.enqueued_jobs.concat(Array.new(400) { :earlier_in_the_run })
      collector = counting_collector
      request = build_request

      collector.begin_request(request)
      adapter.enqueued_jobs.concat(%i[a b])

      expect(collector.collect(request, nil)[:jobs_enqueued]).to eq(Loadwright::Measurement.value(2))
    end

    # A WRONG ATTRIBUTION IS WORSE THAN AN ABSENT ONE here: "this endpoint enqueues
    # 200 jobs" is exactly the kind of finding someone acts on. The counters are
    # process-global, so overlapping requests cannot be told apart -- and overlap is
    # DETECTED rather than inferred from the configured concurrency, because what
    # matters is whether requests actually overlapped.
    it "refuses a per-request count when another request was in flight at the same time" do
      adapter = Class.new { def enqueued_jobs = @jobs ||= [] }.new
      stub_const("ActiveJob::Base", Class.new).tap { |k| k.define_singleton_method(:queue_adapter) { adapter } }
      collector = counting_collector
      first = build_request
      second = build_request

      collector.begin_request(first)
      collector.begin_request(second)
      adapter.enqueued_jobs.concat(%i[a b])

      expect(collector.collect(first, nil)[:jobs_enqueued]).to be_unavailable
      expect(collector.collect(second, nil)[:jobs_enqueued].reason).to include("another request was in flight")
    end

    it "counts again once the requests stop overlapping" do
      adapter = Class.new { def enqueued_jobs = @jobs ||= [] }.new
      stub_const("ActiveJob::Base", Class.new).tap { |k| k.define_singleton_method(:queue_adapter) { adapter } }
      collector = counting_collector

      overlapping = [build_request, build_request]
      overlapping.each { |r| collector.begin_request(r) }
      overlapping.each { |r| collector.collect(r, nil) }

      alone = build_request
      collector.begin_request(alone)
      adapter.enqueued_jobs << :a

      expect(collector.collect(alone, nil)[:jobs_enqueued]).to eq(Loadwright::Measurement.value(1))
    end

    it "omits them rather than reporting zero when the adapters are not in place" do
      collector = counting_collector
      request = build_request
      collector.begin_request(request)

      expect(collector.collect(request, nil)).to eq({})
    end
  end
end

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
    # Containment forces mail and jobs to :test adapters, which RECORD rather than
    # perform. That turns suppression into a measurement: a request enqueuing 200
    # jobs is a finding, and dropping the jobs silently would lose it.
    it "counts recorded mail deliveries when ActionMailer is present" do
      stub_const("ActionMailer::Base", Class.new { def self.deliveries = [1, 2, 3] })
      collector = Class.new(described_class) do
        def collector_name = :fake
        def collect(request, response, capability_epoch: 0) = response_derived(response)
      end.new(config: config)

      expect(collector.collect(build_request, nil)[:mail_deliveries]).to eq(Loadwright::Measurement.value(3))
    end

    it "counts enqueued jobs when the test adapter is in place" do
      adapter = Class.new { def enqueued_jobs = [1, 2] }.new
      stub_const("ActiveJob::Base", Class.new).tap { |k| k.define_singleton_method(:queue_adapter) { adapter } }
      collector = Class.new(described_class) do
        def collector_name = :fake
        def collect(request, response, capability_epoch: 0) = response_derived(response)
      end.new(config: config)

      expect(collector.collect(build_request, nil)[:jobs_enqueued]).to eq(Loadwright::Measurement.value(2))
    end

    it "omits them rather than reporting zero when the adapters are not in place" do
      collector = Class.new(described_class) do
        def collector_name = :fake
        def collect(request, response, capability_epoch: 0) = response_derived(response)
      end.new(config: config)

      expect(collector.collect(build_request, nil)).to eq({})
    end
  end
end

# frozen_string_literal: true

RSpec.describe Loadwright::Instrumentation::ConnectionPoolTracker do
  let(:config) { Loadwright::Configuration.new }

  subject(:tracker) { described_class.new(config: config) }

  describe "against a real connection pool", :sample_app do
    it "samples size, busy and waiting" do
      sample = tracker.sample

      expect(sample.size).to be > 0
      expect(sample.busy).to be >= 0
      expect(sample.waiting).to eq(0)
    end

    it "produces metrics keyed to RequestMetrics' fields" do
      metrics = tracker.metrics

      expect(metrics.keys).to contain_exactly(:pool_size, :pool_busy, :pool_waiting)
      expect(metrics[:pool_size]).to be_available
    end

    # `busy` at the pool size just means the pool is fully used, which under load is
    # what a correctly sized pool looks like. `waiting` above zero means a thread
    # asked for a connection and did not get one — requests queueing behind the pool
    # rather than behind the database. That is the finding.
    it "distinguishes a saturated pool from a starved one" do
      saturated = described_class::Sample.new(size: 5, busy: 5, waiting: 0)
      starved = described_class::Sample.new(size: 5, busy: 5, waiting: 3)

      expect(saturated).to be_saturated
      expect(saturated).not_to be_starved
      expect(starved).to be_starved
    end

    # Peak rather than per-request, because the request that gets starved is usually
    # not the request that caused it.
    it "tracks the peak across samples, not just the latest" do
      allow(ActiveRecord::Base.connection_pool).to receive(:stat).and_return(
        { size: 5, busy: 1, waiting: 0 },
        { size: 5, busy: 5, waiting: 4 },
        { size: 5, busy: 2, waiting: 0 }
      )

      3.times { tracker.sample }

      expect(tracker.peak_waiting).to eq(4)
      expect(tracker.peak_busy).to eq(5)
    end

    it "resets its peaks between cells of the matrix" do
      allow(ActiveRecord::Base.connection_pool).to receive(:stat).and_return({ size: 5, busy: 5, waiting: 9 })
      tracker.sample

      tracker.reset_peaks!

      expect(tracker.peak_waiting).to eq(0)
    end

    it "reports starvation in its audit hash" do
      allow(ActiveRecord::Base.connection_pool).to receive(:stat).and_return({ size: 5, busy: 5, waiting: 2 })
      tracker.sample

      expect(tracker.to_h).to include(available: true, peak_waiting: 2, starved: true)
    end
  end

  describe "when it cannot read the pool" do
    # Each unavailability gets its own reason, because the fix differs.
    it "explains that ActiveRecord is not loaded" do
      hide_const("ActiveRecord")

      expect(tracker).not_to be_available
      expect(tracker.metrics[:pool_size]).to be_unavailable
      expect(tracker.metrics[:pool_size].reason).to include("ActiveRecord is not loaded")
    end

    it "explains that the user turned it off" do
      config.track_connection_pool = false

      expect(tracker).not_to be_available
      expect(tracker.to_h[:unavailable_reason]).to include("track_connection_pool is disabled")
    end

    it "degrades rather than raising when the pool read itself fails", :sample_app do
      allow(ActiveRecord::Base.connection_pool).to receive(:stat).and_raise("pool is gone")

      expect(tracker.sample).to be_nil
      expect(tracker.metrics[:pool_waiting]).to be_unavailable
    end
  end

  # The adapter-agnostic signal is the primary one on purpose: it catches pool
  # exhaustion on SQLite and on databases whose lock introspection Loadwright cannot
  # read, where the Postgres and MySQL probes have nothing to say.
  it "works on an adapter with no lock introspection at all", :sample_app do
    expect(ActiveRecord::Base.connection.adapter_name.downcase).to include("sqlite")

    expect(tracker.sample.size).to be > 0
  end
end

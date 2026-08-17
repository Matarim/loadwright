# frozen_string_literal: true

RSpec.describe Loadwright::Execution::Collector::Direct do
  let(:config) { Loadwright::Configuration.new }
  let(:tracker) { Loadwright::Instrumentation::QueryTracker.new(config: config) }

  subject(:collector) { described_class.new(config: config, tracker: tracker) }

  after { collector.stop_run! }

  it "names itself :direct, which is what CapabilityProfile keys on" do
    expect(collector.collector_name).to eq(:direct)
  end

  it "starts and stops the shared subscriber with the run, not per request" do
    collector.start_run!
    expect(tracker).to be_subscribed

    collector.stop_run!
    expect(tracker).not_to be_subscribed
  end

  describe "#collect" do
    before { collector.start_run! }

    it "returns a query count and duplicate structure from the tracked bucket" do
      request = build_request
      collector.begin_request(request)
      3.times { emit_sql("SELECT * FROM comments WHERE post_id = 7", duration: 0) }
      emit_sql("SELECT * FROM posts", duration: 0)

      metrics = collector.collect(request, nil)

      expect(metrics.query_count).to eq(Loadwright::Measurement.value(4))
      expect(metrics.distinct_query_count).to eq(Loadwright::Measurement.value(2))
      expect(metrics.duplicate_fingerprints.keys).to eq(["SELECT * FROM comments WHERE post_id = ?"])
    end

    it "sums query duration into db_runtime_ms" do
      request = build_request
      collector.begin_request(request)
      emit_sql("SELECT * FROM posts", duration: 2)

      expect(collector.collect(request, nil).db_runtime_ms.value).to be > 0
    end

    it "carries the unattributed count, so GAP-01 is visible in the data" do
      emit_sql("SELECT * FROM posts", duration: 0) # nothing open: unattributable
      request = build_request
      collector.begin_request(request)

      expect(collector.collect(request, nil).unattributed_query_count).to eq(Loadwright::Measurement.value(1))
    end

    # A missing bucket is a harness bug, not an app property. Reporting zero
    # queries here would present the most dangerous wrong number this tool can
    # print — a perfectly optimised endpoint — as the consequence of our own bug.
    it "reports unavailable, not zero, when correlation was never started" do
      metrics = collector.collect(build_request, nil)

      expect(metrics.query_count).to be_unavailable
      expect(metrics.query_count.reason).to include("correlation was not started")
    end

    it "releases the bucket, so a long run does not accumulate every request" do
      request = build_request
      collector.begin_request(request)
      collector.collect(request, nil)

      expect(tracker.bucket(request.request_id)).to be_nil
    end

    describe "the metrics it cannot get here" do
      # These numbers EXIST in :in_process — the harness shares the heap and the
      # pool — but their interpretation does not. CapabilityProfile marks
      # clean_memory_attribution unavailable for exactly that reason, which is why
      # the collector may report them without the report being allowed to call
      # them the app's footprint.
      it "still reports allocations and GC, which the capability profile qualifies" do
        request = build_request
        collector.begin_request(request)

        metrics = collector.collect(request, nil)

        expect(metrics.allocations).to be_available
        profile = Loadwright::CapabilityProfile.derive(transport: :in_process, collector: :direct)
        expect(profile).to be_unavailable(:clean_memory_attribution)
      end

      # hide_const rather than relying on ActiveRecord being absent:
      # examples/sample_app loads it, so whether it is defined here depends on spec
      # ORDER.
      it "reports pool stats as unavailable with a reason when ActiveRecord is absent" do
        hide_const("ActiveRecord")
        request = build_request
        collector.begin_request(request)

        metrics = collector.collect(request, nil)

        expect(metrics.pool_size).to be_unavailable
        expect(metrics.pool_size.reason).to include("ActiveRecord is not loaded")
      end

      # The pool numbers themselves are real in :in_process — the harness shares the
      # app's pool. What CapabilityProfile marks unavailable is the interpretation:
      # this is not a measurement of pool pressure a client would experience,
      # because there are no server threads contending for it.
      it "reports real pool stats when ActiveRecord is present", :sample_app do
        request = build_request
        collector.begin_request(request)

        metrics = collector.collect(request, nil)

        expect(metrics.pool_size.value).to be > 0
        expect(metrics.pool_busy).to be_available
        expect(Loadwright::CapabilityProfile.derive(transport: :in_process, collector: :direct))
          .to be_unavailable(:connection_pool_exhaustion)
      end
    end
  end
end

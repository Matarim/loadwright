# frozen_string_literal: true

RSpec.describe Loadwright::Instrumentation::MemoryTracker do
  let(:config) { Loadwright::Configuration.new }

  subject(:tracker) { described_class.new(config: config) }

  describe "#measure" do
    it "returns the block's result alongside the metrics" do
      result, = tracker.measure { :the_response }

      expect(result).to eq(:the_response)
    end

    it "measures allocations made inside the block" do
      _, metrics = tracker.measure { Array.new(10_000) { +"a string" } }

      expect(metrics[:allocations]).to be_available
      expect(metrics[:allocations].value).to be > 10_000
    end

    it "reports a small delta for a block that allocates little" do
      _, busy = tracker.measure { Array.new(50_000) { +"x" } }
      _, quiet = tracker.measure { nil }

      expect(quiet[:allocations].value).to be < busy[:allocations].value
    end

    it "measures GC activity" do
      _, metrics = tracker.measure { GC.start }

      expect(metrics[:gc_count]).to be_available
      expect(metrics[:gc_count].value).to be >= 1
    end

    # Disabled means unavailable-with-a-reason, never zero. A zero allocation count
    # in a report reads as "measured, and this endpoint allocates nothing".
    it "reports unavailable rather than zero when disabled" do
      config.track_memory_allocations = false

      result, metrics = tracker.measure { :done }

      expect(result).to eq(:done)
      expect(metrics[:allocations]).to be_unavailable
      expect(metrics[:allocations].reason).to include("track_memory_allocations is disabled")
    end
  end

  describe "GC time" do
    # GC.stat's time key is not portable across Ruby builds. Turning a missing key
    # into 0.0 would render as "no GC time" in a report, which is a claim rather
    # than an absence.
    it "is unavailable with a reason rather than zero when the Ruby cannot report it" do
      allow(GC).to receive(:stat).and_return(
        { total_allocated_objects: 100, count: 1 },
        { total_allocated_objects: 200, count: 1 }
      )

      _, metrics = tracker.measure { nil }

      expect(metrics[:gc_time_ms]).to be_unavailable
      expect(metrics[:gc_time_ms].reason).to include("GC total time is unavailable")
      expect(metrics[:allocations].value).to eq(100)
    end

    it "is available on a Ruby that reports total_time_ns" do
      _, metrics = tracker.measure { nil }

      skip "this Ruby does not report GC total time" unless GC.stat.key?(:total_time_ns)
      expect(metrics[:gc_time_ms]).to be_available
    end
  end

  describe "when GC.stat itself is unavailable" do
    it "degrades to unavailable rather than raising mid-run" do
      allow(GC).to receive(:stat).and_raise(NotImplementedError, "not on this VM")

      result, metrics = tracker.measure { :done }

      expect(result).to eq(:done)
      expect(metrics[:allocations]).to be_unavailable
      expect(metrics[:allocations].reason).to include("GC.stat was unavailable")
    end
  end

  describe "#to_h" do
    it "records whether GC total time can be reported at all on this Ruby" do
      expect(tracker.to_h).to include(enabled: true)
      expect(tracker.to_h).to have_key(:gc_total_time_available)
    end
  end
end

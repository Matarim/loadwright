# frozen_string_literal: true

RSpec.describe Loadwright::CapabilityTimeline do
  let(:full) { Loadwright::CapabilityProfile.derive(transport: :http, collector: :middleware) }

  subject(:timeline) { described_class.new(full) }

  it "starts with a single epoch at full capability" do
    expect(timeline.current).to eq(full)
    expect(timeline.current_epoch).to eq(0)
    expect(timeline).not_to be_degraded
  end

  it "rejects anything that is not a CapabilityProfile" do
    expect { described_class.new(:full) }.to raise_error(ArgumentError, /expected a CapabilityProfile/)
  end

  describe "#degrade!" do
    it "opens a new epoch and downgrades from that point forward" do
      epoch = timeline.degrade!(:queries_per_returned_record, reason: "middleware stopped responding")

      expect(epoch).to eq(1)
      expect(timeline).to be_degraded
      expect(timeline.current).to be_unavailable(:queries_per_returned_record)
    end

    # The reason CapabilityProfile stays a frozen value object: results already
    # collected must remain attributed to the capability that was actually in
    # effect when they were collected, not to the degraded one.
    it "leaves earlier epochs intact so past results keep their true attribution" do
      timeline.degrade!(:queries_per_returned_record, reason: "middleware stopped responding")

      expect(timeline.profile_at(0)).to be_available(:queries_per_returned_record)
      expect(timeline.profile_at(1)).to be_unavailable(:queries_per_returned_record)
    end

    it "does not open a redundant epoch when nothing actually changes" do
      timeline.degrade!(:n_plus_one_slope, reason: "middleware stopped responding")
      epoch = timeline.degrade!(:n_plus_one_slope, reason: "middleware stopped responding")

      expect(epoch).to eq(1)
      expect(timeline.epochs.length).to eq(2)
    end

    it "records the cause of each degradation" do
      timeline.degrade!(:n_plus_one_slope, reason: "app process died")
      expect(timeline.epochs.last.cause).to eq("app process died")
    end

    it "requires at least one signal" do
      expect { timeline.degrade!(reason: "x") }.to raise_error(ArgumentError, /at least one signal/)
    end
  end

  describe "#lost_signals" do
    it "reports what the run could measure at the start but cannot now" do
      timeline.degrade!(%i[n_plus_one_slope over_fetch_hint], reason: "app process died")

      expect(timeline.lost_signals).to match_array(%i[n_plus_one_slope over_fetch_hint])
    end

    it "is empty for a run that never degraded" do
      expect(timeline.lost_signals).to be_empty
    end
  end

  describe "#to_h" do
    it "carries enough for a report to render capability per window" do
      timeline.degrade!(:n_plus_one_slope, reason: "app process died")
      hash = timeline.to_h

      expect(hash[:degraded]).to be(true)
      expect(hash[:lost_signals]).to eq([:n_plus_one_slope])
      expect(hash[:epochs].length).to eq(2)
      expect(hash[:epochs].last[:cause]).to eq("app process died")
    end
  end
end

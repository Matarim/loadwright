# frozen_string_literal: true

# performance-signals.md Part 1 makes this REQUIRED, not optional: a run with outbound
# HTTP blocked is faster than production reality, and reporting the number unqualified
# is the same category of error as reporting a 403 as fast.
RSpec.describe Loadwright::Analysis::ContainmentDisclosure do
  def containment(**states)
    measures = states.map do |name, enforced|
      Loadwright::SideEffects::Containment::Measure.new(name: name, requested: true, enforced: enforced)
    end
    instance_double(Loadwright::SideEffects::Containment, measures: measures)
  end

  describe "when containment is on, which is the default" do
    subject(:disclosure) do
      described_class.from(containment(mail: true, background_jobs: true, outbound_http: true))
    end

    it "flags the figures as skewed" do
      expect(disclosure).to be_skewed
    end

    # The direction is what a reader needs BEFORE the number, or they take 340ms at
    # face value.
    it "leads with the direction of the error" do
      expect(disclosure.summary).to start_with("These latency figures are lower than production reality")
    end

    # The subtle part, and the reason words are needed rather than a smaller number: a
    # blocked call contributes to no component, so db + view + gc + other still sums to
    # the total. Nothing in the arithmetic hints that anything is missing.
    it "says the missing time appears in no component at all" do
      expect(disclosure.summary).to include("appears in no component")
    end

    it "points at the signal to read instead of the suppressed job time" do
      expect(disclosure.summary).to include("Jobs enqueued per request is reported separately")
    end
  end

  # The opposite error, and it is a real one: a slow endpoint may be reporting a third
  # party's outage rather than anything about the app.
  describe "when containment is off" do
    subject(:disclosure) do
      described_class.from(containment(mail: false, background_jobs: false, outbound_http: false))
    end

    it "does not claim the figures are understated" do
      expect(disclosure).not_to be_skewed
    end

    it "warns that a slow endpoint may be reporting someone else's latency" do
      expect(disclosure.summary).to include("someone else's outage")
    end

    it "says real mail may have been sent" do
      expect(disclosure.summary).to include("real mail may have been sent")
    end
  end

  # Mail suppression barely moves latency. Letting it set the skew flag would mean every
  # default run is flagged, which makes the flag mean nothing.
  describe "the skew flag" do
    it "is not set by mail suppression alone" do
      expect(described_class.from(containment(mail: true, background_jobs: false, outbound_http: false)))
        .not_to be_skewed
    end

    it "is set by blocked outbound HTTP" do
      expect(described_class.from(containment(mail: false, background_jobs: false, outbound_http: true)))
        .to be_skewed
    end

    it "still records mail suppression, since it matters for safety even when timing does not" do
      disclosure = described_class.from(containment(mail: true, background_jobs: false, outbound_http: false))

      expect(disclosure.notes.map(&:measure)).to include(:mail)
    end
  end

  describe "with no containment object at all" do
    it "says so rather than implying containment was active" do
      expect(described_class.none.summary).to be_nil
      expect(described_class.from(nil).skewed?).to be(false)
    end
  end

  it "serialises to something a report can render without recomputing anything" do
    serialised = described_class.from(containment(outbound_http: true, background_jobs: true)).to_h

    expect(serialised[:skewed]).to be(true)
    expect(serialised[:notes].map { |note| note[:measure] }).to contain_exactly(:outbound_http,
                                                                               :background_jobs)
  end
end

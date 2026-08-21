# frozen_string_literal: true

RSpec.describe Loadwright::Analysis::Statistics do
  let(:config) { Loadwright::Configuration.new }

  subject(:stats) { described_class.new(config: config) }

  def sample(count, from: 1) = (from...(from + count)).map(&:to_f)

  describe "#summarize" do
    it "reports the sample count alongside everything else, so a reader can judge the figures" do
      summary = stats.summarize(sample(25))

      expect(summary.sample_count).to eq(25)
    end

    it "computes min, median and max, which are defensible at any sample size" do
      summary = stats.summarize([10.0, 30.0, 20.0])

      expect(summary.min).to eq(10.0)
      expect(summary.median).to eq(20.0)
      expect(summary.max).to eq(30.0)
    end

    it "interpolates between order statistics rather than picking the nearest rank" do
      # Nearest-rank on 100 samples would return the 100th value for p99 -- the maximum,
      # relabelled. Type 7 interpolation puts it between the 99th and 100th.
      summary = stats.summarize(sample(500))

      expect(summary.percentiles[:p99].value).to be_within(0.01).of(495.01)
      expect(summary.percentiles[:p99].value).to be < summary.max
    end

    it "handles a single sample without dividing by zero" do
      summary = stats.summarize([7.0])

      expect(summary.median).to eq(7.0)
      expect(summary.stddev).to be_nil
    end

    it "handles an empty sample without inventing anything" do
      summary = stats.summarize([])

      expect(summary.sample_count).to eq(0)
      expect(summary.median).to be_nil
      expect(summary.percentiles[:p50]).to be_unavailable
    end
  end

  # THE POINT OF THE WHOLE CLASS. A p99 from 25 samples is the maximum with a decimal
  # point on it, and printing it with a caveat is not good enough -- a reader who skims
  # sees a number.
  describe "percentiles the sample size cannot support" do
    it "omits them rather than reporting noise" do
      summary = stats.summarize(sample(25))

      expect(summary.percentiles[:p50]).to be_available
      expect(summary.percentiles[:p95]).to be_unavailable
      expect(summary.percentiles[:p99]).to be_unavailable
    end

    it "states how many samples the omitted percentile needed, and how many there were" do
      summary = stats.summarize(sample(25))

      expect(summary.percentiles[:p99].reason).to include("need 500", "have 25")
    end

    it "names the config key that fixes it, since the reader's next question is 'how'" do
      summary = stats.summarize(sample(25))

      expect(summary.percentiles[:p99].reason).to include("requests_per_endpoint_per_level")
    end

    it "reports every percentile once the sample supports it" do
      summary = stats.summarize(sample(500))

      expect(summary.percentiles.values).to all(be_available)
      expect(summary.omitted).to be_empty
    end

    it "honours a raised min_samples_for_percentiles" do
      config.min_samples_for_percentiles = { p50: 1000, p95: 1000, p99: 1000 }

      expect(stats.summarize(sample(500)).percentiles[:p50]).to be_unavailable
    end
  end

  describe "dispersion" do
    it "reports the coefficient of variation, so a mean dragged by outliers is visible" do
      summary = stats.summarize([100.0, 100.0, 100.0, 100.0, 5000.0])

      expect(summary.coefficient_of_variation).to be_available
      expect(summary).to be_high_variance
    end

    it "does not call three near-identical samples high variance" do
      expect(stats.summarize([100.0, 101.0, 99.0])).not_to be_high_variance
    end

    it "refuses to compute dispersion from two samples rather than reporting zero spread" do
      summary = stats.summarize([100.0, 200.0])

      expect(summary.coefficient_of_variation).to be_unavailable
      expect(summary.coefficient_of_variation.reason).to include("at least 3 samples")
    end

    # Zero mean means a degenerate sample, and stddev/mean is undefined rather than
    # infinite. Returning Float::INFINITY would render as a number.
    it "refuses to divide by a zero mean" do
      summary = stats.summarize([0.0, 0.0, 0.0])

      expect(summary.coefficient_of_variation).to be_unavailable
    end
  end

  describe "#detector_state -- what the latency finding class is allowed to claim" do
    it "is available once at least one cell supports the lowest percentile" do
      summaries = [stats.summarize(sample(2)), stats.summarize(sample(25))]

      expect(stats.detector_state(summaries)).to eq(:available)
    end

    # Below the p50 floor we have a handful of timings and nothing defensible to say
    # about them, which is a genuine coverage gap rather than a clean result.
    it "is unavailable when no cell reached even the lowest percentile's minimum" do
      state, reason = stats.detector_state([stats.summarize(sample(5))])

      expect(state).to eq(:unavailable)
      expect(reason).to include("5 request(s)", "p50 needs 20", "requests_per_endpoint_per_level")
    end

    it "is unavailable, with a different reason, when no latency was collected at all" do
      state, reason = stats.detector_state([])

      expect(state).to eq(:unavailable)
      expect(reason).to include("no latency samples")
    end
  end

  describe "#budget_check" do
    it "flags a budget the observed percentile exceeds" do
      check = stats.budget_check(stats.summarize(Array.new(25, 800.0)), 500)

      expect(check).to be_exceeded
      expect(check.observed_ms).to eq(800.0)
    end

    it "clears a budget the observed percentile meets" do
      expect(stats.budget_check(stats.summarize(Array.new(25, 100.0)), 500)).not_to be_exceeded
    end

    # p95_latency_budget_ms names p95, and 25 samples cannot support p95. Refusing to
    # check anything would make latency permanently unanswerable at DEFAULT settings,
    # which is the coverage flooding the three-state model exists to prevent.
    it "checks the highest supported percentile and names which one it used" do
      check = stats.budget_check(stats.summarize(sample(25)), 500)

      expect(check.checked_at).to eq(:p50)
    end

    it "states plainly that a p50 within budget does not prove p95 is" do
      check = stats.budget_check(stats.summarize(sample(25)), 500)

      expect(check.caveat).to include("does not prove p95")
    end

    it "carries no caveat once the top percentile is genuinely supported and the spread is tight" do
      # A tight cluster: p99 supported, so nothing is being substituted, and the CV is
      # low, so nothing is being dragged by outliers. Both caveats are then absent.
      check = stats.budget_check(stats.summarize(Array.new(500) { |i| 100.0 + (i % 5) }), 5000)

      expect(check.checked_at).to eq(:p99)
      expect(check.caveat).to be_nil
    end

    it "discloses high variance on the figure it just checked" do
      values = Array.new(24, 100.0) + [10_000.0]
      check = stats.budget_check(stats.summarize(values), 50)

      expect(check.caveat).to include("high variance")
    end

    it "returns nothing when no percentile was supported, rather than guessing" do
      expect(stats.budget_check(stats.summarize(sample(3)), 500)).to be_nil
    end

    it "returns nothing when no budget is configured for the endpoint" do
      expect(stats.budget_check(stats.summarize(sample(25)), nil)).to be_nil
    end
  end

  describe "#budget_for" do
    it "prefers an endpoint-specific budget over the default" do
      config.p95_latency_budget_ms = { "GET /slow" => 5_000, default: 500 }

      expect(stats.budget_for("GET /slow")).to eq(5_000)
      expect(stats.budget_for("GET /other")).to eq(500)
    end

    it "is nil when neither is configured" do
      config.p95_latency_budget_ms = {}

      expect(stats.budget_for("GET /x")).to be_nil
    end
  end

  # run-comparison.md: a latency delta must clear BOTH the configured threshold and the
  # measured run-to-run variance. This is the second half.
  describe "the noise floor" do
    it "is the widest relative gap observed between two runs of the same commit" do
      floor = stats.noise_floor_from([[100.0, 110.0], [200.0, 240.0]])

      expect(floor.value).to be_within(0.001).of(0.20)
    end

    it "is unavailable, not zero, when no paired baseline was recorded" do
      floor = stats.noise_floor_from([])

      expect(floor).to be_unavailable
      expect(floor.reason).to include("noise floor is unmeasured")
    end

    it "raises the bar a latency delta must clear when the measured noise exceeds the threshold" do
      config.regression_threshold_pct = 20
      floor = Loadwright::Measurement.value(0.35)

      expect(stats.latency_regression?(100.0, 130.0, noise_floor: floor)).to be(false)
      expect(stats.latency_regression?(100.0, 140.0, noise_floor: floor)).to be(true)
    end

    it "never lowers the bar below the configured threshold, however quiet the machine" do
      config.regression_threshold_pct = 20

      expect(stats.bar(Loadwright::Measurement.value(0.02))).to be_within(0.0001).of(0.20)
    end

    it "falls back to the configured threshold alone when the noise floor is unmeasured" do
      config.regression_threshold_pct = 20

      expect(stats.latency_regression?(100.0, 125.0, noise_floor: nil)).to be(true)
      expect(stats.latency_regression?(100.0, 115.0, noise_floor: nil)).to be(false)
    end

    it "is not a regression when latency improved" do
      expect(stats.latency_regression?(200.0, 100.0)).to be(false)
    end
  end
end

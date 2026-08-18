# frozen_string_literal: true

RSpec.describe Loadwright::EndpointOutcome do
  let(:endpoint) { "GET /api/v1/posts" }

  describe "the three states" do
    it "has exactly three, never two" do
      expect(described_class::STATES).to eq(%i[healthy has_findings inconclusive])
    end

    it "builds a healthy outcome" do
      outcome = described_class.healthy(endpoint: endpoint)
      expect(outcome).to be_healthy
      expect(outcome).not_to be_inconclusive
      expect(outcome.findings).to be_empty
    end

    it "builds an outcome with findings" do
      outcome = described_class.has_findings(endpoint: endpoint, findings: ["N+1 in PostSerializer"])
      expect(outcome).to be_has_findings
      expect(outcome.findings).to eq(["N+1 in PostSerializer"])
    end

    it "refuses a findings outcome with no findings" do
      expect { described_class.has_findings(endpoint: endpoint, findings: []) }
        .to raise_error(ArgumentError, /at least one finding/)
    end
  end

  describe "inconclusive" do
    # The failure mode this state exists to prevent: a 403 in 4ms with one query
    # is the healthiest-looking endpoint in the API to a query-counting tool.
    it "requires a known reason" do
      outcome = described_class.inconclusive(endpoint: endpoint, reason: :unsuccessful_status)

      expect(outcome).to be_inconclusive
      expect(outcome.explanation).to match(/an error path was measured/)
    end

    it "rejects an unknown reason rather than accepting free text" do
      expect { described_class.inconclusive(endpoint: endpoint, reason: :vibes) }
        .to raise_error(ArgumentError, /unknown inconclusive reason/)
    end

    it "appends caller detail to the canonical explanation" do
      outcome = described_class.inconclusive(
        endpoint: endpoint, reason: :path_params_unresolved, detail: "could not resolve :slug"
      )
      expect(outcome.explanation).to match(/could not resolve :slug/)
    end

    # response-analysis.md Part 1: excluded from the clean list, the summary
    # rankings, and any pass/fail exit code.
    it "never counts as clean" do
      outcome = described_class.inconclusive(endpoint: endpoint, reason: :empty_with_seeded_data)
      expect(outcome).not_to be_countable_as_clean
    end

    it "counts a healthy endpoint as clean" do
      expect(described_class.healthy(endpoint: endpoint)).to be_countable_as_clean
    end

    it "does not count an endpoint with findings as clean" do
      outcome = described_class.has_findings(endpoint: endpoint, findings: ["x"])
      expect(outcome).not_to be_countable_as_clean
    end
  end

  describe "distinguishing kinds of inconclusive" do
    # reporting.md section 4: quarantined (our load caused it) and externally
    # blocked (someone else's lock) must render distinctly — they mean
    # different things and prompt different actions.
    it "identifies quarantine, where our own load caused the contention" do
      outcome = described_class.inconclusive(endpoint: endpoint, reason: :quarantined)
      expect(outcome).to be_quarantined
      expect(outcome).not_to be_externally_blocked
    end

    it "identifies an external blocker, which says nothing about the endpoint" do
      outcome = described_class.inconclusive(endpoint: endpoint, reason: :externally_blocked)
      expect(outcome).to be_externally_blocked
      expect(outcome).not_to be_quarantined
    end

    it "identifies endpoints that were never reached" do
      outcome = described_class.inconclusive(endpoint: endpoint, reason: :circuit_breaker)
      expect(outcome).to be_skipped
      expect(outcome).not_to be_quarantined
    end

    it "keeps quarantine a reason rather than a fourth state" do
      outcome = described_class.inconclusive(endpoint: endpoint, reason: :quarantined)
      expect(outcome.state).to eq(:inconclusive)
    end
  end

  describe "capability attribution" do
    it "records which capability epoch produced the outcome" do
      outcome = described_class.healthy(endpoint: endpoint, capability_epoch: 2)
      expect(outcome.capability_epoch).to eq(2)
    end
  end

  it "is frozen" do
    expect(described_class.healthy(endpoint: endpoint)).to be_frozen
  end
end

# The coverage-derived state rule. Added when `has_findings` with
# `confidence: :none` was retired as a category error — see response-analysis.md,
# "Outcome state is derived from coverage".
RSpec.describe Loadwright::EndpointOutcome, ".derive" do
  let(:endpoint) { "GET /api/v1/posts" }

  def coverage(**detectors) = Loadwright::Coverage.new(detectors)

  def full_coverage
    coverage(pattern_match: :available, slope: :available, payload_growth: :available,
             query_response_comparison: :available)
  end

  # THE WORKED CASE the rule exists to settle. The slope could not be measured, but
  # the pattern-match detector ran and came back clean — so the N+1 class WAS covered,
  # just with one detector instead of two. That is healthy, not inconclusive.
  it "is healthy when a class is covered by one of its two detectors" do
    outcome = described_class.derive(
      endpoint: endpoint,
      coverage: coverage(pattern_match: :available,
                         slope: [:unavailable, "result size could not be varied"],
                         payload_growth: :available, query_response_comparison: :available)
    )

    expect(outcome).to be_healthy
    expect(outcome.coverage.describe).to include("N+1 (pattern)")
  end

  it "is healthy when every applicable class is covered and nothing was found" do
    expect(described_class.derive(endpoint: endpoint, coverage: full_coverage)).to be_healthy
  end

  # If BOTH N+1 detectors failed, an N+1 cannot be ruled out.
  it "is inconclusive when a class has no coverage at all, naming the class" do
    outcome = described_class.derive(
      endpoint: endpoint,
      coverage: coverage(pattern_match: [:unavailable, "no query data was collected"],
                         slope: [:unavailable, "result size could not be varied"],
                         payload_growth: :available)
    )

    expect(outcome).to be_inconclusive
    expect(outcome.reason).to eq(:incomplete_coverage)
    expect(outcome).to be_incomplete_coverage
    expect(outcome.detail).to include("N+1")
    expect(outcome.detail).to include("no query data was collected")
  end

  # Findings take precedence over a coverage gap: a concrete defect is the most
  # actionable thing we can say, and the gap stays visible because coverage is
  # attached regardless.
  it "is has_findings when something was found, even with a coverage gap" do
    outcome = described_class.derive(
      endpoint: endpoint,
      findings: [:an_n_plus_one],
      coverage: coverage(pattern_match: [:unavailable, "no query data"], slope: [:unavailable, "no variance"])
    )

    expect(outcome).to be_has_findings
    expect(outcome.coverage.uncovered_classes).to include(:n_plus_one)
  end

  # An unmeasurable signal must never inflate the finding count.
  it "counts no finding for a coverage gap" do
    outcome = described_class.derive(
      endpoint: endpoint,
      coverage: coverage(pattern_match: [:unavailable, "no query data"], slope: [:unavailable, "no variance"])
    )

    expect(outcome.findings).to be_empty
  end

  # Reported on every endpoint regardless of state, so reporting renders it rather
  # than recomputing it.
  it "attaches coverage to every state" do
    [
      described_class.derive(endpoint: endpoint, coverage: full_coverage),
      described_class.derive(endpoint: endpoint, findings: [:x], coverage: full_coverage),
      described_class.inconclusive(endpoint: endpoint, reason: :unsuccessful_status, coverage: full_coverage)
    ].each do |outcome|
      expect(outcome.coverage).to eq(full_coverage)
      expect(outcome.to_h[:coverage][:description]).to be_a(String)
    end
  end

  it "defaults to no coverage rather than nil, so callers never branch on absence" do
    expect(described_class.healthy(endpoint: endpoint).coverage).to eq(Loadwright::Coverage.none)
  end

  # An incomplete-coverage endpoint is still not clean — that is the whole point of
  # not calling it healthy.
  it "is never countable as clean when coverage is incomplete" do
    outcome = described_class.derive(
      endpoint: endpoint,
      coverage: coverage(pattern_match: [:unavailable, "no query data"], slope: [:unavailable, "no variance"])
    )

    expect(outcome).not_to be_countable_as_clean
  end
end

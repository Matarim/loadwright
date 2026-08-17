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

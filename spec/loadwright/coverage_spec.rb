# frozen_string_literal: true

RSpec.describe Loadwright::Coverage do
  def coverage(**detectors) = described_class.new(detectors)

  describe "a class is covered by ANY of its detectors" do
    # Two detectors for one class is redundancy, not a requirement. If the
    # pattern-match detector ran and came back clean, the N+1 class was covered; the
    # slope being unmeasurable does not change what we can honestly say.
    it "is covered when only the pattern-match detector answered" do
      subject = coverage(pattern_match: :available, slope: [:unavailable, "result size could not be varied"])

      expect(subject).to be_covered(:n_plus_one)
      expect(subject).not_to be_uncovered(:n_plus_one)
    end

    it "is covered when only the slope detector answered" do
      subject = coverage(pattern_match: [:unavailable, "no query data"], slope: :available)

      expect(subject).to be_covered(:n_plus_one)
    end

    # If BOTH N+1 detectors failed, an N+1 genuinely cannot be ruled out.
    it "is uncovered when every detector for the class failed" do
      subject = coverage(pattern_match: [:unavailable, "no query data"],
                         slope: [:unavailable, "result size could not be varied"])

      expect(subject).not_to be_covered(:n_plus_one)
      expect(subject).to be_uncovered(:n_plus_one)
    end
  end

  # The third state is what stops this flooding every report with `inconclusive`.
  describe "not_applicable versus unavailable" do
    it "treats an unmentioned detector as never attempted" do
      subject = coverage(pattern_match: :available)

      expect(subject).to be_not_applicable(:index_scan)
      expect(subject).not_to be_uncovered(:index_scan)
      expect(subject[:explain].state).to eq(:not_applicable)
    end

    it "does not let a never-attempted detector make the run incomplete" do
      # ExplainAnalyzer and Statistics are not in this build. Reporting them as gaps
      # would make every endpoint inconclusive until they ship.
      subject = coverage(pattern_match: :available, payload_growth: :available,
                         query_response_comparison: :available)

      expect(subject).to be_complete
      expect(subject.uncovered_classes).to be_empty
      expect(subject.not_applicable_classes).to contain_exactly(:index_scan, :latency)
    end

    it "requires a reason for an unavailable detector, since the reason is the output" do
      expect { coverage(slope: [:unavailable, nil]) }
        .to raise_error(ArgumentError, /requires a reason/)
      expect { coverage(slope: :unavailable) }
        .to raise_error(ArgumentError, /requires a reason/)
    end

    it "allows a reason on a not-applicable detector, so the report can say why" do
      subject = coverage(payload_growth: [:not_applicable, "only one scale factor is configured"])

      expect(subject).to be_not_applicable(:missing_pagination)
      expect(subject.describe).to include("only one scale factor is configured")
    end
  end

  # A hint that must never fail a build cannot be allowed to force `inconclusive`,
  # which is a strictly stronger statement than a hint.
  describe "advisory classes" do
    it "never escalates an over-fetch gap to a coverage gap" do
      subject = coverage(pattern_match: :available, payload_growth: :available,
                         query_response_comparison: [:unavailable, "no queried tables were recorded"])

      expect(subject).to be_complete
      expect(subject.uncovered_classes).to be_empty
    end

    it "still reports the over-fetch gap, so the reader sees it was not checked" do
      subject = coverage(pattern_match: :available,
                         query_response_comparison: [:unavailable, "no queried tables were recorded"])

      expect(subject).to be_unanswered(:over_fetch)
      expect(subject.describe).to include("over-fetch")
      expect(subject.to_h[:unanswered]).to include(:over_fetch)
    end
  end

  # Reported on EVERY endpoint regardless of state. This is what makes the rule honest
  # rather than merely tidy — reduced coverage is visible without overloading
  # `inconclusive` to signal it.
  describe "#describe" do
    it "names what was checked and what was not" do
      subject = coverage(
        pattern_match: :available,
        slope: [:unavailable, "result size could not be varied"],
        payload_growth: :available,
        query_response_comparison: :available
      )

      description = subject.describe

      expect(description).to include("checked:")
      expect(description).to include("pagination")
      expect(description).to include("not checked: index analysis")
      expect(description).to include("latency percentiles")
    end

    # The detail that matters for the worked case: the N+1 class is listed as checked,
    # but annotated so a reader knows one of its two detectors answered.
    it "notes when a class was covered by only some of its detectors" do
      subject = coverage(pattern_match: :available, slope: [:unavailable, "result size could not be varied"])

      expect(subject.describe).to include("N+1 (pattern)")
    end

    it "does not annotate a class whose only detector answered" do
      subject = coverage(payload_growth: :available)

      expect(subject.describe).to include("pagination")
      expect(subject.describe).not_to include("pagination (payload growth)")
    end
  end

  describe "#uncovered_detail" do
    it "names the class and why, for the inconclusive reason" do
      subject = coverage(pattern_match: [:unavailable, "no query data was collected"],
                         slope: [:unavailable, "result size could not be varied"])

      expect(subject.uncovered_detail).to include("N+1")
      expect(subject.uncovered_detail).to include("no query data was collected")
    end
  end

  # A TRIPWIRE, not a tautology. The advisory list is a hazard as well as a mechanism:
  # the foreseeable misuse is someone adding a noisy class to it to quiet a report,
  # which launders a real signal through a mechanism built for an unfalsifiable one.
  # Pinning the membership means an addition cannot be made without editing this
  # example, and editing it means reading the rule.
  describe "the advisory list" do
    it "contains exactly the classes justified by the admission rule" do
      expect(described_class::ADVISORY_CLASSES).to eq(%i[over_fetch]),
                                                   <<~WHY
                                                     ADVISORY_CLASSES changed.

                                                     A class may be advisory ONLY if its findings are inherently unfalsifiable from
                                                     Loadwright's vantage point — the same observation produced by correct and by
                                                     incorrect code, with nothing we can see to tell them apart. Over-fetch qualifies
                                                     because authorization, filtering and callbacks produce it exactly as readily as a
                                                     wasteful eager load.

                                                     "Noisy" and "low confidence" are NOT grounds — those are detection problems, and
                                                     the fix is better detection, not exemption from the state model.

                                                     If the new class genuinely qualifies, write the justification into
                                                     response-analysis.md ("Admission rule") first, then update this expectation.
                                                   WHY
    end

    it "is documented with its admission rule where someone adding to it will look" do
      source = File.read(File.join(SpecPaths::LIB, "coverage.rb"))

      expect(source).to match(/ADMISSION RULE/)
      expect(source).to match(/inherently unfalsifiable/i)
      expect(source).to match(/NOT grounds/)
    end

    # SKIPS WHERE THE DESIGN DOCS ARE NOT PRESENT, rather than failing. They are
    # internal notes and are not published with the gem, so a fresh clone of the
    # public repository does not have them -- and a suite that fails on checkout for
    # a missing private file teaches the first contributor that red is normal.
    #
    # The check still runs wherever the docs ARE present, which is where the rule it
    # guards can actually be violated. Found by cloning the published repository and
    # running the suite, which is the only way this shows up.
    it "is stated in the reference doc, since admission is a documentation change first" do
      path = File.join(SpecPaths::REFERENCES, "response-analysis.md")
      skip "design references are not part of the published repository" unless File.exist?(path)

      doc = SpecPaths.read(path)

      expect(doc).to include("Admission rule")
      # Whitespace-tolerant: the phrase wraps across lines inside a blockquote, and a
      # spec that broke on reflowing a paragraph would be deleted rather than fixed.
      expect(doc).to match(/inherently\s+(?:>\s+)?unfalsifiable/i)
      expect(doc).to match(/not\s+grounds/i)
    end
  end

  it "rejects an unknown detector name rather than silently ignoring a typo" do
    expect { coverage(patern_match: :available) }.to raise_error(ArgumentError, /unknown detector/)
  end

  it "rejects an unknown finding class" do
    expect { coverage.covered?(:vibes) }.to raise_error(ArgumentError, /unknown finding class/)
  end

  it "is frozen and value-comparable" do
    expect(coverage(pattern_match: :available)).to be_frozen
    expect(coverage(pattern_match: :available)).to eq(coverage(pattern_match: :available))
    expect(coverage(pattern_match: :available)).not_to eq(described_class.none)
  end
end

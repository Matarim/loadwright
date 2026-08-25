# frozen_string_literal: true

RSpec.describe Loadwright::Reporting::ComparisonReport do
  let(:config) { Loadwright::Configuration.new }

  subject(:report) { described_class.new(config: config) }

  def comparison(**rest)
    Loadwright::History::Comparator::Result.new(
      **{ comparable: true, divergences: [], warnings: [], new_findings: [], resolved_findings: [],
          changed_findings: [], deltas: [], transitions: [], endpoints_added: [],
          endpoints_removed: [], excluded_signals: [] }.merge(rest)
    )
  end

  def delta(verdict:, metric: "queries (cell)", **rest)
    Loadwright::History::Comparator::Delta.new(
      **{ endpoint: "GET /a", metric: metric, before: 3, after: 47, change: 14.6, verdict: verdict }
        .merge(rest)
    )
  end

  # A REFUSAL RENDERS NOTHING ELSE. Showing deltas below a notice saying they are
  # meaningless is an invitation to read them anyway, and the reader who skims is
  # exactly the reader the gate exists to protect.
  describe "when the runs are not comparable" do
    let(:refused) do
      comparison(
        comparable: false,
        divergences: [Loadwright::History::Comparator::Divergence.new(
          dimension: "config.concurrency_levels", before: [1], after: [1, 20]
        )],
        deltas: [delta(verdict: :regression)],
        new_findings: [{ endpoint: "GET /a", finding: "n_plus_one_slope" }]
      )
    end

    it "names the diverging dimension and both values" do
      text = report.render(refused)

      expect(text).to include("config.concurrency_levels")
      expect(text).to include("[1, 20]")
    end

    it "renders no deltas and no findings at all" do
      text = report.render(refused)

      expect(text).not_to include("n_plus_one_slope")
      expect(text).not_to include("Regressions")
    end

    it "says what to do rather than only that it refused" do
      expect(report.render(refused)).to include("Re-run one side under matching configuration")
    end
  end

  describe "section order" do
    let(:full) do
      comparison(
        new_findings: [{ endpoint: "GET /a", finding: "n_plus_one_slope" }],
        deltas: [delta(verdict: :regression), delta(verdict: :within_noise, metric: "p50 latency (cell)")],
        resolved_findings: [{ endpoint: "GET /b", finding: "missing_pagination", resolved: true }],
        transitions: [Loadwright::History::Comparator::Transition.new(
          endpoint: "GET /c", before: "has_findings", after: "inconclusive", note: "became unmeasurable"
        )]
      )
    end

    it "leads with what broke" do
      text = report.render(full)

      expect(text.index("New findings")).to be < text.index("Regressions")
      expect(text.index("New findings")).to be < text.index("Resolved")
    end

    # An endpoint that became unmeasurable has lost its findings in the arithmetic. A
    # reader who meets the resolved list FIRST concludes their fix worked.
    it "puts state changes before resolved findings" do
      text = report.render(full)

      expect(text.index("State changes")).to be < text.index("Resolved")
    end

    # THE ROWS MOST LIKELY TO BE MISREAD AS WINS. A query count that fell because
    # the endpoint returned fewer records looks like a fix and is not one. A reader
    # who reaches "Resolved" -- or just the "No regressions." line -- without passing
    # these concludes their change worked.
    describe "changes whose basis moved" do
      let(:with_unattributable) do
        comparison(
          deltas: [delta(verdict: :unattributable, metric: "queries (seed_scale scale=10)",
                         before: 31, after: 6,
                         note: "the number of records returned changed too")],
          resolved_findings: [{ endpoint: "GET /a", finding: "n_plus_one_slope", resolved: true }]
        )
      end

      it "renders them rather than dropping them for having no verdict" do
        text = report.render(with_unattributable)

        expect(text).to include("Changed, but not like-for-like")
        expect(text).to include("31")
        expect(text).to include("6")
      end

      it "says why the comparison does not hold" do
        expect(report.render(with_unattributable)).to include("the number of records returned changed too")
      end

      it "places them above anything that reads as good news" do
        text = report.render(with_unattributable)

        expect(text.index("Changed, but not like-for-like")).to be < text.index("Resolved")
      end

      # Neither bucket. Filing it as either would be the verdict the data cannot
      # support, which is the whole reason the state exists.
      it "keeps them out of both the regression and the within-noise tables" do
        result = with_unattributable

        expect(result.regressions).to be_empty
        expect(result.within_noise).to be_empty
        expect(result.unattributable.length).to eq(1)
      end
    end

    it "puts within-noise changes last and separates them from regressions" do
      text = report.render(full)

      expect(text.index("Within noise")).to be > text.index("Regressions")
      expect(text).to include("never presented as a regression").or include("none is reported as a regression")
    end

    it "leads the whole document with the verdict" do
      expect(report.render(full)).to include("**REGRESSED**")
    end
  end

  describe "a finding that vanished because the endpoint stopped being measurable" do
    it "is rendered as NOT a fix, in the resolved section where it would otherwise mislead" do
      text = report.render(comparison(
                             resolved_findings: [{ endpoint: "GET /a", finding: "n_plus_one_slope",
                                                   resolved: false,
                                                   note: "the endpoint became INCONCLUSIVE" }]
                           ))

      expect(text).to include("NOT a fix")
      expect(text).to include("became INCONCLUSIVE")
    end
  end

  describe "a clean comparison" do
    it "says so rather than rendering empty tables" do
      text = report.render(comparison)

      expect(text).to include("No regressions.")
      expect(text).to include("Nothing broke that was not already broken.")
    end
  end

  describe "caveats" do
    it "surfaces excluded signals, so a missing delta is never silently missing" do
      text = report.render(comparison(
                             excluded_signals: [{ metric: :queries, signal: :n_plus_one_pattern_match,
                                                  detail: "queries cannot be compared" }]
                           ))

      expect(text).to include("queries cannot be compared")
    end

    it "surfaces machine and worktree warnings" do
      text = report.render(comparison(warnings: ["measured on different machines"]))

      expect(text).to include("measured on different machines")
    end
  end

  describe "#render_html" do
    it "produces a self-contained document" do
      html = report.render_html(comparison)

      expect(html).to start_with("<!doctype html>")
      expect(html).not_to match(/<link[^>]+href=/i)
    end

    it "escapes the rendered content" do
      text = report.render_html(comparison(warnings: ["<script>alert(1)</script>"]))

      expect(text).not_to include("<script>alert")
    end
  end

  describe "#write!" do
    it "picks the format from the extension" do
      require "tmpdir"
      Dir.mktmpdir do |dir|
        markdown = report.write!(comparison, path: File.join(dir, "c.md"))
        html = report.write!(comparison, path: File.join(dir, "c.html"))

        expect(File.read(markdown)).to start_with("# Loadwright comparison")
        expect(File.read(html)).to start_with("<!doctype html>")
      end
    end
  end
end

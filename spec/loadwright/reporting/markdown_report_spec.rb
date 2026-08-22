# frozen_string_literal: true

RSpec.describe Loadwright::Reporting::MarkdownReport do
  subject(:report) { described_class.new(config: report_config) }

  def render(**rest) = report.render(build_result(**rest))

  let(:inconclusive) do
    build_outcome(endpoint: build_endpoint(path: "/admin/stats"), state: :inconclusive,
                  reason: :unsuccessful_status)
  end

  # ==========================================================================
  # THE HAZARD THIS FORMAT CARRIES. It is the one most likely to be pasted somewhere
  # without its context, and it has no colour to lean on -- so every distinction the
  # HTML report makes visually has to survive here as TEXT.
  # ==========================================================================
  describe "what has to survive being pasted" do
    it "spells out each state in words rather than relying on styling" do
      text = render(outcomes: [inconclusive])

      expect(text).to include("INCONCLUSIVE")
    end

    it "leads with the sensitivity notice, before anything worth scrolling past" do
      expect(render.lines.first).to include(">")
      expect(render).to start_with("> This report may contain data drawn from your database")
    end

    it "says an inconclusive endpoint is not a pass" do
      text = render(outcomes: [inconclusive])

      expect(text).to include("**not** counted as passing")
      expect(text).to include("nothing was checked — not that nothing is wrong")
    end
  end

  describe "tables" do
    it "escapes a pipe so a detail string cannot silently break the table" do
      finding = build_finding(detail: "a | b")
      text = render(outcomes: [build_outcome(endpoint: build_endpoint, state: :has_findings,
                                             findings: [finding])])

      expect(text).to include('a \| b')
    end

    it "collapses a newline in a detail, which would otherwise end the row early" do
      finding = build_finding(detail: "line one\nline two")
      text = render(outcomes: [build_outcome(endpoint: build_endpoint, state: :has_findings,
                                             findings: [finding])])

      expect(text).to include("line one line two")
    end

    it "gives every table as many headers as it has columns" do
      # A mismatched header count renders as a broken table, and a broken table in a
      # pasted report reads as a bug in the tool.
      render(timeline: degraded_timeline).scan(/^\|.*\|$\n^\|[-|]+\|$/m) do |_|
        nil
      end

      render(timeline: degraded_timeline).split("\n\n").each do |block|
        rows = block.lines.select { |line| line.start_with?("|") }
        next if rows.length < 2

        widths = rows.map { |row| row.count("|") }
        expect(widths.uniq.length).to eq(1), "ragged table:\n#{block}"
      end
    end
  end

  describe "capability" do
    it "renders per window rather than as one claim for the whole run" do
      text = render(timeline: degraded_timeline)

      expect(text).to include("Window 1", "Window 2")
      expect(text).to include("Capability degraded mid-run")
    end

    it "renders the reason a signal is unavailable" do
      text = render(timeline: degraded_timeline(reason: "the middleware stopped answering"))

      expect(text).to include("the middleware stopped answering")
    end

    it "says so plainly when everything was available" do
      timeline = Loadwright::CapabilityTimeline.new(
        Loadwright::CapabilityProfile.derive(transport: :http, collector: :middleware)
      )

      expect(render(timeline: timeline)).to include("Everything Loadwright measures was available")
    end
  end

  describe "the header" do
    it "states the execution mode and the transport/collector pairing" do
      expect(render).to include("| Execution mode | http |").or include("http → middleware")
    end
  end

  it "marks an aborted run partial" do
    expect(render(aborted_reason: "circuit breaker tripped")).to include("**Partial run.**")
  end

  it "shows the concurrency a stepped-down cell actually ran at" do
    text = render(cells: [build_cell(requested: 20, actual: 5)],
                  outcomes: [build_outcome(endpoint: build_endpoint, state: :has_findings,
                                           findings: [build_finding])])

    expect(text).to include("5 (stepped down from 20)").or include("stepped down")
  end
end

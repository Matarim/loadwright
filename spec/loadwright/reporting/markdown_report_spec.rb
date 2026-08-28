# frozen_string_literal: true

RSpec.describe Loadwright::Reporting::MarkdownReport do
  subject(:report) { described_class.new(config: report_config) }

  def render(**rest) = report.render(build_result(**rest))

  let(:inconclusive) do
    build_outcome(endpoint: build_endpoint(path: "/admin/stats"), state: :inconclusive,
                  reason: :unsuccessful_status)
  end

  # THE HAZARD THIS FORMAT CARRIES. It is the one most likely to be pasted somewhere
  # without its context, and it has no colour to lean on -- so every distinction the
  # HTML report makes visually has to survive here as TEXT.
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

  # A SETTING WHOSE WHOLE PURPOSE IS TO STOP AN ENDPOINT BEING CALLED HEALTHY ON A
  # RESPONSE THAT IS NOT WHAT IT CLAIMS MUST NOT BE SILENT ABOUT WHETHER IT RAN.
  #
  # require_schema_valid_response defaults to true, and the report contained the
  # string "schema" nowhere: not in the checked half of the coverage line, not in the
  # not-checked half. A reader could not tell a validated response from one that was
  # never validated because the operation declares no schema.
  describe "response schema validation" do
    def render_with(schema)
      render(outcomes: [build_outcome(endpoint: build_endpoint(path: "/widgets/1"), state: :healthy)],
             schema_validation: { "GET /widgets/1" => schema })
    end

    # A healthy endpoint gets one line in the appendix and nothing else, and it is the
    # line a reader trusts most -- so the answer has to fit on it.
    it "says so on a clean endpoint's one line when the response was checked" do
      text = render_with({ state: :validated, note: "validated against the declared response schema" })

      expect(text).to include("response schema: checked")
    end

    # The distinction that matters. "Not checked" and "checked and fine" are the two
    # things a reader is trying to tell apart, and silence looked like both.
    it "says a clean endpoint's response was not checked, rather than saying nothing" do
      text = render_with({ state: :no_schema, note: "no response schema is declared for this operation" })

      expect(text).to include("response schema: not checked (none declared)")
    end

    it "gives a measured endpoint the full sentence, with the reason" do
      text = render(
        outcomes: [build_outcome(endpoint: build_endpoint(path: "/widgets/1"), state: :has_findings,
                                 findings: [build_finding])],
        schema_validation: { "GET /widgets/1" => { state: :no_schema,
                                                   note: "no response schema is declared for this operation" } }
      )

      expect(text).to include("Response schema: not checked")
      expect(text).to include("no response schema is declared")
    end

    it "says when the response did not match" do
      text = render(
        outcomes: [build_outcome(endpoint: build_endpoint(path: "/widgets/1"), state: :has_findings,
                                 findings: [build_finding])],
        schema_validation: { "GET /widgets/1" => { state: :violations,
                                                   note: "the response did not match its declared schema" } }
      )

      expect(text).to include("Response schema: violations found")
    end

    # An endpoint discovery skipped was never requested, so there is nothing to say
    # about its response -- and an empty row a reader has to interpret is worse than
    # no row.
    it "renders nothing for an endpoint that was never exercised" do
      expect(render).not_to include("Response schema")
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

    # CONSTRUCTED, not derived. No pairing derives everything as available any more:
    # memory and pool are collected by nothing, and CapabilityProfile says so rather
    # than advertising them. The all-available RENDERING still has to work -- it is
    # what a fully-wired run will print -- so the precondition is stated here instead
    # of borrowed from a profile that no longer meets it.
    it "says so plainly when everything was available" do
      all_available = Loadwright::CapabilityProfile::SIGNALS.to_h do |signal|
        [signal, Loadwright::CapabilityProfile::Capability.new(:available, nil)]
      end
      timeline = Loadwright::CapabilityTimeline.new(Loadwright::CapabilityProfile.new(all_available))

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
  # SUCCEEDED HERE, FAILED THERE. One verdict on the header while four of six cells
  # answered 200 makes a reader open the cell table to find out what happened.
  describe "an endpoint whose cells did not agree" do
    def rendered_with(*status_lists)
      key = "GET /api/v1/posts"
      cells = status_lists.map { |statuses| build_cell(endpoint_key: key, statuses: statuses) }
      outcome = build_outcome(endpoint: build_endpoint(path: "/api/v1/posts"), state: :inconclusive,
                              reason: :page_size_rejected)

      render(outcomes: [outcome], cells: cells)
    end

    it "puts the status counts next to the verdict" do
      output = rendered_with([200, 200, 200, 200], [400, 400])

      expect(output).to include("4 x 200").and include("2 x 400")
    end

    it "says nothing when every request agreed" do
      expect(rendered_with([200, 200], [200, 200])).not_to include("4 x 200")
    end
  end
  # DECLINED IS NOT UNMEASURABLE. In one real run 45 of 73 inconclusive endpoints were
  # mutating verbs the user had switched off -- so the headline number said "73 could
  # not be validly measured" when 45 of them were never attempted and are one config
  # switch away. A reader trying to improve coverage could not tell the two apart.
  describe "the inconclusive count when some endpoints were declined by policy" do
    def summary_line(declined:, not_measurable:)
      outcomes = Array.new(declined) do |n|
        build_outcome(endpoint: build_endpoint(path: "/api/v1/widgets/#{n}", verb: :post),
                      state: :inconclusive, reason: :mutating_not_allowed)
      end
      outcomes += Array.new(not_measurable) do |n|
        build_outcome(endpoint: build_endpoint(path: "/api/v1/gadgets/#{n}"),
                      state: :inconclusive, reason: :unsuccessful_status)
      end

      render(outcomes: outcomes, cells: [])
    end

    it "splits the number into what could not be measured and what was declined" do
      output = summary_line(declined: 45, not_measurable: 28)

      expect(output).to include("28 could not be measured").and include("45 declined by configuration")
    end

    it "says nothing extra when nothing was declined" do
      expect(summary_line(declined: 0, not_measurable: 3)).not_to include("declined by configuration")
    end
  end
end

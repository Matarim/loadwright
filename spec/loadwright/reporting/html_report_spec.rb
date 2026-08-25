# frozen_string_literal: true

require "cgi"

RSpec.describe Loadwright::Reporting::HtmlReport do
  subject(:report) { described_class.new(config: report_config) }

  def render(**rest) = report.render(build_result(**rest))

  describe "self-containment" do
    # A report gets emailed, attached to a ticket, and opened on a laptop on a train.
    # One that needs the network renders blank exactly when someone is trying to use it.
    it "references nothing outside the file" do
      html = render

      expect(html).not_to match(%r{<script[^>]+src=}i)
      expect(html).not_to match(/<link[^>]+href=/i)
      expect(html).not_to match(%r{https?://(?!www\.w3\.org)}i)
    end

    it "inlines its stylesheet" do
      expect(render).to include("<style>")
    end

    it "is a complete document" do
      expect(render).to start_with("<!doctype html>")
    end
  end

  # THE THREE STATES. An endpoint we could not validly measure must never render
  # like one that passed.
  describe "endpoint states" do
    let(:inconclusive) do
      build_outcome(endpoint: build_endpoint(path: "/admin/stats"), state: :inconclusive,
                    reason: :unsuccessful_status)
    end

    it "labels each state distinctly in the summary" do
      text = visible_text(render)

      expect(text).to include("healthy", "with findings", "inconclusive")
    end

    it "gives an inconclusive endpoint a different CSS class from a healthy one" do
      html = render(outcomes: [inconclusive])

      expect(html).to include("state-inconclusive")
      expect(html).not_to match(/class="endpoint state-healthy"/)
    end

    it "says outright that an inconclusive endpoint is not a pass" do
      text = visible_text(render(outcomes: [inconclusive]))

      expect(text).to include("Not measured")
      expect(text).to include("nothing was checked — not that nothing is wrong")
    end

    it "renders the reason it could not be measured, since that is the actionable part" do
      text = visible_text(render(outcomes: [inconclusive]))

      expect(text).to include("an error path was measured")
    end

    # "18 endpoints clean" is a lie if 12 of them were inconclusive.
    it "never folds inconclusive endpoints into the clean count" do
      text = visible_text(render(outcomes: [inconclusive]))

      expect(text).to include("0 endpoints measured clean")
      expect(text).to include("NOT counted as passing")
    end

    it "puts findings above inconclusive above healthy, since a gap is unfinished business" do
      html = render(outcomes: [
                      build_outcome(endpoint: build_endpoint(path: "/c"), state: :healthy),
                      inconclusive,
                      build_outcome(endpoint: build_endpoint(path: "/a"), state: :has_findings,
                                    findings: [build_finding])
                    ])

      expect(html.index("GET /a")).to be < html.index("GET /admin/stats")
    end
  end

  # CAPABILITY PER WINDOW. A single "this mode supports X" banner is a lie in any
  # degraded run -- which is the run where a wrong claim does the most damage.
  describe "capability rendering" do
    it "renders one window for a run that never degraded" do
      text = visible_text(render)

      expect(text).to include("Throughout the run")
      expect(text).not_to include("Window 2")
    end

    it "renders a window per epoch once capability changed" do
      text = visible_text(render(timeline: degraded_timeline))

      expect(text).to include("Window 1", "Window 2")
    end

    it "names what was lost and warns that results split across windows" do
      text = visible_text(render(timeline: degraded_timeline))

      expect(text).to include("Capability degraded mid-run")
      expect(text).to include("n_plus_one_slope")
      expect(text).to include("attributed to")
    end

    it "shows the cause of the downgrade rather than only that one happened" do
      text = visible_text(render(timeline: degraded_timeline(reason: "the app process died")))

      expect(text).to include("Entered because: the app process died")
    end

    # The reason is the whole value of an unavailable signal: it tells the reader
    # whether to change execution mode, install the middleware, or raise a sample size.
    # A blank cell says only that a number is missing.
    it "renders why an unavailable signal is unavailable, never just that it is" do
      text = visible_text(render(timeline: degraded_timeline(reason: "the middleware stopped answering")))

      expect(text).to include("the middleware stopped answering")
    end

    it "renders the structural reasons a profile carries from the start" do
      timeline = Loadwright::CapabilityTimeline.new(
        Loadwright::CapabilityProfile.derive(transport: :in_process, collector: :direct)
      )

      expect(visible_text(render(timeline: timeline)))
        .to include("in-process execution has no server thread pool")
    end
  end

  describe "the metadata header" do
    it "states the execution mode and the transport/collector pairing" do
      text = visible_text(render)

      expect(text).to include("Execution mode")
      expect(text).to include("http → middleware")
    end
  end

  describe "an aborted run" do
    # The abort is usually the most interesting finding in the report, and a partial
    # report mistaken for a complete one under-reports the API silently.
    it "is marked partial at the very top" do
      text = visible_text(render(aborted_reason: "circuit breaker tripped"))

      expect(text).to include("Partial run")
      expect(text).to include("circuit breaker tripped")
      expect(text.index("Partial run")).to be < text.index("Summary")
    end

    it "says the missing endpoints were not necessarily clean" do
      text = visible_text(render(aborted_reason: "interrupted"))

      expect(text).to include("not necessarily clean")
    end
  end

  # A number a reader takes away has to be the number that happened.
  describe "a cell that was stepped down" do
    it "shows the level it actually ran at, not the level requested" do
      text = visible_text(render(cells: [build_cell(requested: 20, actual: 5)],
                                 outcomes: [build_outcome(endpoint: build_endpoint,
                                                          state: :has_findings,
                                                          findings: [build_finding])]))

      expect(text).to include("5 (stepped down from 20)")
    end
  end

  describe "escaping" do
    it "escapes content drawn from the app under test" do
      finding = build_finding(detail: "<script>alert('x')</script>")
      html = render(outcomes: [build_outcome(endpoint: build_endpoint, state: :has_findings,
                                             findings: [finding])])

      expect(html).not_to include("<script>alert")
      expect(html).to include("&lt;script&gt;")
    end
  end

  describe "#write!" do
    it "writes the document to disk" do
      require "tmpdir"
      Dir.mktmpdir do |dir|
        path = File.join(dir, "nested", "report.html")
        report.write!(build_result, path: path)

        expect(File.read(path)).to start_with("<!doctype html>")
      end
    end
  end
end

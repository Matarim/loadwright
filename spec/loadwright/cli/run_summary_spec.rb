# frozen_string_literal: true

require "loadwright/cli"
require "stringio"

# THE CONSOLE SUMMARY IS THE ONLY THING MOST PEOPLE READ, and three separate rounds
# found it saying something a reader would act on wrongly. It had no specs at all.
RSpec.describe Loadwright::CLI::RunCommand, "the console summary" do
  let(:stdout) { StringIO.new }
  let(:report_config) { Loadwright::Configuration.new }

  subject(:command) do
    described_class.new(options: { dry_run: true }, stdout: stdout, stderr: StringIO.new)
  end

  def summarise(result)
    command.send(:print_summary, result, [])
    stdout.string
  end

  def finding_outcome(path)
    build_outcome(endpoint: build_endpoint(path: path), state: :has_findings,
                  findings: [build_finding(kind: :n_plus_one_slope)])
  end

  # "4 with findings", three printed, no indication a fourth existed -- and the one it
  # dropped was the worst endpoint in the run: a 17-repeat N+1 at twice its latency
  # budget. A reader who trusts the console and never opens the report does not learn
  # it is there.
  it "says how many findings it did not print" do
    outcomes = (1..4).map { |i| finding_outcome("/api/v1/widgets/#{i}") }

    text = summarise(build_result(outcomes: outcomes))

    expect(text).to include("...and 1 more finding(s)")
  end

  it "stays quiet when it printed all of them" do
    outcomes = (1..2).map { |i| finding_outcome("/api/v1/widgets/#{i}") }

    expect(summarise(build_result(outcomes: outcomes))).not_to include("more finding(s)")
  end

  # "0 healthy, 0 with findings, 163 inconclusive" is the summary of a run that reached
  # none of the API, and it reads as a survey that found nothing wrong.
  it "says outright when nothing was measured" do
    unmeasured = build_outcome(endpoint: build_endpoint(path: "/api/v1/widgets"),
                               state: :inconclusive, reason: :endpoint_erroring)

    text = summarise(build_result(outcomes: [unmeasured], aborted_reason: "circuit breaker tripped"))

    expect(text).to include("NOTHING WAS MEASURED")
    expect(text).to include("It is not a clean result")
  end

  it "does not say it when something was measured" do
    healthy = build_outcome(endpoint: build_endpoint(path: "/api/v1/posts"), state: :healthy)

    expect(summarise(build_result(outcomes: [healthy]))).not_to include("NOTHING WAS MEASURED")
  end

  # The run opened with "87 endpoint(s) to exercise" and closed with "163 endpoint(s)".
  # Reconcilable, never reconciled, and 163 was not a number anyone could hand on.
  it "reconciles its own endpoint count when some were never requested" do
    healthy = build_outcome(endpoint: build_endpoint(path: "/api/v1/posts"), state: :healthy)
    declined = build_outcome(endpoint: build_endpoint(path: "/api/v1/posts", verb: :post),
                             state: :inconclusive, reason: :mutating_not_allowed)

    text = summarise(build_result(outcomes: [healthy, declined]))

    expect(text).to include("1 exercised plus 1 never requested")
    expect(text).to include("mutating_not_allowed")
  end
end

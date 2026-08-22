# frozen_string_literal: true

RSpec.describe Loadwright::Reporting::JsonReport do
  subject(:report) { described_class.new(config: report_config) }

  def document(**rest) = JSON.parse(report.render(build_result(**rest)))

  it "produces parseable JSON" do
    expect { document }.not_to raise_error
  end

  it "carries the same sections every other format renders from" do
    expect(document.keys).to include("metadata", "summary", "endpoints", "cells")
  end

  # ==========================================================================
  # THE PROPERTY THIS FORMAT MUST NOT LOSE. A null in a JSON document is read as zero
  # or missing by whatever consumes it next, which reintroduces the confidently-wrong
  # number at the one point where the type information would otherwise be gone.
  # ==========================================================================
  describe "unavailable measurements" do
    it "serialises as a reason, never as null" do
      metrics = Loadwright::Execution::RequestMetrics.unavailable(
        request_id: "r", reason: "no collector middleware", collector: :external
      )
      serialised = metrics.to_h

      expect(serialised[:query_count]).to eq(unavailable: "no collector middleware")
      expect(serialised[:query_count]).not_to be_nil
    end

    it "tells a consumer how to read one, rather than leaving it to be inferred" do
      schema = document["schema"]

      expect(schema["measurement"]).to include("unavailable")
      expect(schema["measurement"]).to include("Never null, never 0")
    end

    it "names the three states and what inconclusive means" do
      schema = document["schema"]

      expect(schema["states"]).to eq(%w[healthy has_findings inconclusive])
      expect(schema["inconclusive"]).to include("NOT a pass")
    end
  end

  # This is the format most likely to be attached to a ticket or piped into another
  # tool, and the one nobody reads before sharing.
  describe "redaction" do
    it "goes through the same redactor as the persisted run record" do
      redactor = Loadwright::History::Redactor.new(config: report_config)
      allow(redactor).to receive(:document).and_call_original

      described_class.new(config: report_config, redactor: redactor).render(build_result)

      expect(redactor).to have_received(:document).at_least(:once)
    end

    it "strips a host out of a free-text reason" do
      result = build_result(aborted_reason: "the app at http://staging.acme.internal:3000 stopped answering")

      expect(report.render(result)).not_to include("staging.acme.internal")
    end
  end

  describe "#write!" do
    it "writes the document to disk" do
      require "tmpdir"
      Dir.mktmpdir do |dir|
        path = File.join(dir, "run.json")
        report.write!(build_result, path: path)

        expect { JSON.parse(File.read(path)) }.not_to raise_error
      end
    end
  end
end

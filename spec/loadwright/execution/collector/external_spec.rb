# frozen_string_literal: true

RSpec.describe Loadwright::Execution::Collector::External do
  let(:config) { Loadwright::Configuration.new }

  subject(:collector) { described_class.new(config: config) }

  it "names itself :external" do
    expect(collector.collector_name).to eq(:external)
  end

  describe "#collect" do
    let(:response) do
      Loadwright::Execution::RawResponse.new(
        request: build_request, status: 200, headers: { "content-type" => "application/json" },
        body: "[]", latency_ms: 12.5
      )
    end

    # THE ASSERTION THIS COLLECTOR EXISTS FOR. Zero queries is the single most
    # dangerous wrong number this tool could print, because it reads as a
    # perfectly optimised endpoint. An endpoint that "has no N+1" because nobody
    # was watching is not the same as one that has no N+1.
    it "reports every query-derived field as unavailable, never as zero" do
      metrics = collector.collect(build_request, response)

      %i[query_count distinct_query_count db_runtime_ms view_runtime_ms allocations].each do |field|
        expect(metrics[field]).to be_unavailable, "#{field} was available in an external collection"
        expect(metrics[field].reason).to include("no collector middleware")
      end
    end

    it "refuses to hand out a number at all for an unavailable field" do
      metrics = collector.collect(build_request, response)

      expect { metrics.query_count.value }.to raise_error(Loadwright::UnavailableMeasurementError)
      expect(metrics.any_query_data?).to be(false)
    end

    it "serialises unavailability as a reason, not as nil" do
      serialised = collector.collect(build_request, response).to_h

      expect(serialised[:query_count]).to eq({ unavailable: described_class::REASON })
      expect(serialised[:query_count]).not_to have_key(:value)
    end

    it "records which collector produced it, so a report can explain the degradation" do
      expect(collector.collect(build_request, response).collector).to eq(:external)
    end
  end

  describe "capability" do
    # The requirement from execution-modes.md: the SAME transport with different
    # collectors must yield different capability, so a regression that re-keys
    # capability off execution_mode fails loudly.
    it "reduces capability relative to the middleware collector on the same transport" do
      instrumented = Loadwright::CapabilityProfile.derive(transport: :http, collector: :middleware)
      degraded = Loadwright::CapabilityProfile.derive(transport: :http, collector: :external)

      expect(instrumented).to be_available(:queries_per_returned_record)
      expect(degraded).to be_unavailable(:queries_per_returned_record)
      expect(degraded.unavailable_signals).not_to eq(instrumented.unavailable_signals)
    end

    # response-analysis.md: report the available subset rather than dropping the
    # endpoint entirely. A degraded run is still useful — it just has to announce
    # its degradation.
    it "keeps the purely response-derived signals working" do
      degraded = Loadwright::CapabilityProfile.derive(transport: :http, collector: :external)

      expect(degraded).to be_available(:response_validity_gate)
      expect(degraded).to be_available(:payload_growth_pagination)
      expect(degraded).to be_available(:true_client_latency)
    end
  end
end

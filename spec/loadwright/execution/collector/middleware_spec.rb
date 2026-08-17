# frozen_string_literal: true

RSpec.describe Loadwright::Execution::Collector::Middleware do
  let(:config) { Loadwright::Configuration.new }
  let(:request) { build_request }

  def response_with(headers)
    Loadwright::Execution::RawResponse.new(
      request: request, status: 200, headers: headers, body: "[]", latency_ms: 20.0
    )
  end

  def collector(detail: nil, fetch_error: nil)
    fetcher = if fetch_error
                ->(_uri) { raise fetch_error }
              else
                ->(_uri) { JSON.generate(detail || { "queries" => [] }) }
              end

    described_class.new(config: config, base_url: "http://127.0.0.1:9999", secret: "s", fetcher: fetcher)
  end

  it "names itself :middleware" do
    expect(collector.collector_name).to eq(:middleware)
  end

  describe "the header channel" do
    it "reads the query count off the response headers" do
      metrics = collector.collect(request, response_with(
                                            Loadwright::Execution::CollectorMiddleware::QUERY_COUNT_HEADER => "42",
                                            Loadwright::Execution::CollectorMiddleware::DISTINCT_QUERY_HEADER => "3"
                                          ))

      expect(metrics.query_count).to eq(Loadwright::Measurement.value(42))
      expect(metrics.distinct_query_count).to eq(Loadwright::Measurement.value(3))
    end

    it "reads db runtime and allocations when the target returns them" do
      metrics = collector.collect(request, response_with(
                                            Loadwright::Execution::CollectorMiddleware::QUERY_COUNT_HEADER => "4",
                                            Loadwright::Execution::CollectorMiddleware::DB_RUNTIME_HEADER => "18.75",
                                            Loadwright::Execution::CollectorMiddleware::ALLOCATIONS_HEADER => "9001"
                                          ))

      expect(metrics.db_runtime_ms).to eq(Loadwright::Measurement.value(18.75))
      expect(metrics.allocations).to eq(Loadwright::Measurement.value(9001.0))
    end

    it "marks a header the target did not send as unavailable, not zero" do
      metrics = collector.collect(request, response_with(
                                            Loadwright::Execution::CollectorMiddleware::QUERY_COUNT_HEADER => "4"
                                          ))

      expect(metrics.view_runtime_ms).to be_unavailable
      expect(metrics.view_runtime_ms.reason).to include("was not returned by the target")
    end

    it "marks a non-numeric header as unavailable rather than coercing it to zero" do
      metrics = collector.collect(request, response_with(
                                            Loadwright::Execution::CollectorMiddleware::QUERY_COUNT_HEADER => "4",
                                            Loadwright::Execution::CollectorMiddleware::DB_RUNTIME_HEADER => "n/a"
                                          ))

      expect(metrics.db_runtime_ms).to be_unavailable
      expect(metrics.db_runtime_ms.reason).to include("was not numeric")
    end
  end

  describe "the detail channel" do
    it "brings back fingerprints and call sites" do
      detail = {
        "query_count" => 2,
        "unattributed_query_count" => 0,
        "queries" => [
          { "fingerprint" => "SELECT * FROM comments WHERE post_id = ?", "duration_ms" => 0.4,
            "name" => "Comment Load",
            "call_site" => { "path" => "/app/serializers/post_serializer.rb", "line" => 12,
                             "label" => "comments_count" } }
        ]
      }

      metrics = collector(detail: detail).collect(
        request,
        response_with(Loadwright::Execution::CollectorMiddleware::QUERY_COUNT_HEADER => "2")
      )

      expect(metrics.queries.first[:fingerprint]).to eq("SELECT * FROM comments WHERE post_id = ?")
      expect(metrics.queries.first[:call_site][:label]).to eq("comments_count")
    end

    # The counts are the most reliable signal this tool has. Discarding them
    # because the richer channel failed would lose the good data along with the
    # bad — which is why the two channels are separate in the first place.
    it "keeps the header-derived counts when the detail fetch fails" do
      subject = collector(fetch_error: "connection reset")

      metrics = subject.collect(
        request,
        response_with(Loadwright::Execution::CollectorMiddleware::QUERY_COUNT_HEADER => "17")
      )

      expect(metrics.query_count).to eq(Loadwright::Measurement.value(17))
      expect(metrics.queries).to be_empty
      expect(subject).to be_degraded
      expect(subject.degradation[:signals]).to contain_exactly(:over_fetch_hint, :explain_index_analysis)
    end
  end

  describe "mid-run degradation" do
    # THE CASE THAT MATTERS. If the middleware stops answering, this collector must
    # not keep producing plausible numbers and must not produce zeroes. It records
    # a degradation; ExecutionContext turns that into a capability epoch.
    it "reports unavailable and degrades when the correlation header disappears" do
      subject = collector

      metrics = subject.collect(request, response_with("content-type" => "application/json"))

      expect(metrics.query_count).to be_unavailable
      expect(metrics.query_count.reason).to include("did not respond on this request")
      expect(subject).to be_degraded
      expect(subject.degradation[:signals]).to include(:n_plus_one_slope, :queries_per_returned_record)
      expect(subject.degradation[:reason]).to include("stopped attaching correlation headers")
    end

    it "keeps the response-derived half of the metrics available" do
      subject = collector
      stub_const("ActionMailer::Base", Class.new { def self.deliveries = [] })

      metrics = subject.collect(request, response_with({}))

      expect(metrics.mail_deliveries).to eq(Loadwright::Measurement.value(0))
    end
  end
end

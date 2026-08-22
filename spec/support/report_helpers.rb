# frozen_string_literal: true

# Builds RunResults for the report specs without booting Rails.
#
# The reports render from `RunResult#to_h`, so these construct that shape directly.
# The real end-to-end rendering is asserted in end_to_end_spec against a live run —
# these exist to drive the cases a fixture cannot conveniently produce: a degraded
# capability timeline, an aborted run, a stepped-down cell.
module ReportHelpers
  def report_config = @report_config ||= Loadwright::Configuration.new

  def build_outcome(endpoint:, state: :healthy, findings: [], reason: nil, detail: nil, coverage: nil)
    case state
    when :healthy
      Loadwright::EndpointOutcome.healthy(endpoint: endpoint, coverage: coverage)
    when :has_findings
      Loadwright::EndpointOutcome.has_findings(endpoint: endpoint, findings: findings, coverage: coverage)
    when :inconclusive
      Loadwright::EndpointOutcome.inconclusive(endpoint: endpoint, reason: reason, detail: detail,
                                               coverage: coverage)
    end
  end

  def build_finding(kind: :n_plus_one_slope, confidence: :high, detail: "detail", evidence: {})
    Loadwright::Analysis::ResponseCorrelator::Finding.new(
      kind: kind, confidence: confidence, detail: detail, evidence: evidence
    )
  end

  def build_endpoint(path: "/api/v1/posts", verb: :get)
    Loadwright::Discovery::Endpoint.new(path: path, verb: verb, source: :openapi)
  end

  def build_cell(endpoint_key: "GET /api/v1/posts", requested: 1, actual: nil, skipped_reason: nil, **rest)
    Loadwright::Engine::LoadRunner::Cell.new(
      endpoint_key: endpoint_key, sweep: :seed_scale, scale_factor: 10, page_size: nil,
      requested_concurrency: requested, actual_concurrency: actual || requested,
      requests: 25, latencies: [1.0, 2.0], query_counts: [3], record_counts: [5], bytes: [100],
      statuses: [200], errors: [], contention_events: 0, db_runtimes: [], duplicates: {}, tables: [],
      cold_latencies: [], jobs_enqueued: [], rate_limit_headers: {}, view_runtimes: [], gc_times: [],
      skipped_reason: skipped_reason, **rest
    )
  end

  # A timeline that lost a signal partway, for the per-window rendering rule.
  def degraded_timeline(reason: "the collector middleware stopped answering")
    timeline = Loadwright::CapabilityTimeline.new(
      Loadwright::CapabilityProfile.derive(transport: :http, collector: :middleware)
    )
    timeline.degrade!(:n_plus_one_slope, :queries_per_returned_record, reason: reason)
    timeline
  end

  def build_context(timeline: nil)
    context = instance_double(Loadwright::Execution::ExecutionContext)
    allow(context).to receive(:transport).and_return(double(name: :http))
    allow(context).to receive(:collector).and_return(double(collector_name: :middleware))
    allow(context).to receive(:to_h).and_return(capabilities: (timeline || default_timeline).to_h)
    context
  end

  def default_timeline
    Loadwright::CapabilityTimeline.new(
      Loadwright::CapabilityProfile.derive(transport: :http, collector: :middleware)
    )
  end

  def build_result(outcomes: nil, cells: nil, timeline: nil, **rest)
    Loadwright::Reporting::RunResult.new(
      config: report_config,
      context: build_context(timeline: timeline),
      cells: cells || [build_cell],
      outcomes: outcomes || [build_outcome(endpoint: build_endpoint)],
      started_at: Time.at(1_700_000_000),
      finished_at: Time.at(1_700_000_012),
      **rest
    )
  end

  # Strips tags so an assertion can be about what a READER sees rather than about
  # markup that happens to contain the right substring in an attribute.
  def visible_text(html)
    body = html[html.index("<main>")..]
    text = body.gsub(%r{<script.*?</script>}m, " ").gsub(/<[^>]+>/, " ")
    CGI.unescapeHTML(text).gsub(/\s+/, " ")
  end
end

RSpec.configure { |config| config.include ReportHelpers }

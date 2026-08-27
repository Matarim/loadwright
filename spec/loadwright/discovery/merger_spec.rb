# frozen_string_literal: true

RSpec.describe Loadwright::Discovery::Merger do
  let(:config) { Loadwright::Configuration.new }

  subject(:merger) { described_class.new(config: config) }

  def endpoint(path:, verb: :get, source: :openapi, **rest)
    Loadwright::Discovery::Endpoint.new(path: path, verb: verb, source: source, **rest)
  end

  describe "merging by key" do
    it "collapses the same (template, verb) from two sources into one endpoint" do
      result = merger.merge(
        openapi: [endpoint(path: "/api/v1/posts/{id}", source: :openapi)],
        integration_spec: [endpoint(path: "/api/v1/posts/{id}", source: :integration_spec,
                                    recorded_path_values: { id: %w[42] })]
      )

      expect(result.endpoints.length).to eq(1)
      expect(result.endpoints.first.sources).to contain_exactly(:openapi, :integration_spec)
      expect(result.endpoints.first.recorded_path_values).to eq(id: %w[42])
    end

    it "keeps endpoints that differ only by verb apart" do
      config.allow_mutating_requests = true

      result = merger.merge(
        openapi: [
          endpoint(path: "/api/v1/posts", verb: :get),
          endpoint(path: "/api/v1/posts", verb: :post, request_body: { "title" => "x" })
        ]
      )

      expect(result.endpoints.map(&:to_s)).to contain_exactly("GET /api/v1/posts", "POST /api/v1/posts")
    end

    # Route discovery is gap-filling: it must not displace a documented endpoint,
    # and it must contribute the ones nothing else knows about.
    it "lets route discovery fill gaps without displacing richer sources" do
      result = merger.merge(
        openapi: [endpoint(path: "/api/v1/posts", source: :openapi, operation_id: "listPosts")],
        route: [endpoint(path: "/api/v1/posts", source: :route),
                endpoint(path: "/api/v1/health", source: :route)]
      )

      documented = result.endpoints.find { |e| e.path == "/api/v1/posts" }
      expect(documented.operation_id).to eq("listPosts")
      expect(result.endpoints.map(&:path)).to include("/api/v1/health")
    end

    it "sorts the result, so a run's endpoint order is stable across invocations" do
      result = merger.merge(
        openapi: [endpoint(path: "/z"), endpoint(path: "/a"), endpoint(path: "/m")]
      )

      expect(result.endpoints.map(&:path)).to eq(%w[/a /m /z])
    end
  end

  describe "mutating requests" do
    let(:sources) do
      { openapi: [endpoint(path: "/api/v1/posts", verb: :post, request_body: { "title" => "x" })] }
    end

    # Opt-in separately from the environment gate: even in development, a
    # badly-scoped DELETE in a scaled load test can wipe out seed data a developer
    # cares about.
    it "excludes them by default, and says why" do
      result = merger.merge(**sources)

      expect(result.endpoints).to be_empty
      expect(result.skipped.length).to eq(1)
      expect(result.skipped.first.detail).to include("allow_mutating_requests is false")
    end

    it "includes them once the user opts in" do
      config.allow_mutating_requests = true

      expect(merger.merge(**sources).endpoints.length).to eq(1)
    end
  end

  describe "endpoints with no usable example" do
    # "Discovered but no example available; skipped" — recorded as an outcome, not
    # silently omitted, so the reader knows the endpoint exists and was not covered.
    it "reports them as inconclusive with an actionable reason" do
      config.allow_mutating_requests = true
      result = merger.merge(route: [endpoint(path: "/api/v1/posts", verb: :post, source: :route)])

      expect(result.endpoints).to be_empty
      outcome = result.skipped.first
      expect(outcome).to be_inconclusive
      expect(outcome.reason).to eq(:no_example_available)
      expect(outcome.detail).to include("record a request spec")
    end
  end

  describe "path filters" do
    # An endpoint the user excluded is out of scope, not a failure. Reporting it as
    # inconclusive would make excluded_paths look like a source of problems.
    it "drops excluded paths entirely rather than reporting them as inconclusive" do
      result = merger.merge(
        openapi: [endpoint(path: "/api/v1/posts"), endpoint(path: "/admin/users")]
      )

      expect(result.endpoints.map(&:path)).to eq(["/api/v1/posts"])
      expect(result.skipped).to be_empty
    end

    it "honours the shipped default exclusions" do
      result = merger.merge(
        openapi: [endpoint(path: "/rails/info"), endpoint(path: "/health"), endpoint(path: "/api/v1/posts")]
      )

      expect(result.endpoints.map(&:path)).to eq(["/api/v1/posts"])
    end

    it "treats included_paths as an allowlist" do
      config.included_paths = [%r{^/api/v1/orders}]
      result = merger.merge(
        openapi: [endpoint(path: "/api/v1/orders"), endpoint(path: "/api/v1/posts")]
      )

      expect(result.endpoints.map(&:path)).to eq(["/api/v1/orders"])
    end

    it "applies excluded_paths even inside included_paths" do
      config.included_paths = [%r{^/api}]
      config.excluded_paths = [%r{^/api/v1/internal}]
      result = merger.merge(
        openapi: [endpoint(path: "/api/v1/internal/debug"), endpoint(path: "/api/v1/posts")]
      )

      expect(result.endpoints.map(&:path)).to eq(["/api/v1/posts"])
    end
  end

  describe "#to_h" do
    it "summarises coverage and every skip for the report" do
      config.excluded_paths = []
      result = merger.merge(
        openapi: [endpoint(path: "/api/v1/posts"), endpoint(path: "/api/v1/posts", verb: :delete)],
        warnings: ["12 recorded requests could not be mapped to a route template"]
      )

      audit = result.to_h

      expect(audit[:endpoint_count]).to eq(1)
      expect(audit[:skipped_count]).to eq(1)
      expect(audit[:by_source]).to eq(openapi: 1)
      expect(audit[:skipped].first[:endpoint]).to eq("DELETE /api/v1/posts")
      expect(audit[:warnings].first).to include("could not be mapped")
    end
  end
  # DECLINED BY POLICY IS NOT UNMEASURABLE. A mutating endpoint we chose not to request
  # and an endpoint we had nothing to send are different situations with different
  # fixes, and they shared a reason symbol -- so in one real run 45 of 73 inconclusive
  # endpoints were the first kind and a reader could not tell that most of their
  # coverage gap was one config switch away.
  describe "an endpoint declined because it mutates" do
    let(:outcome) do
      config.allow_mutating_requests = false
      post = Loadwright::Discovery::Endpoint.new(path: "/api/v1/widgets", verb: :post, source: :openapi,
                                                 request_body: { "name" => "x" })

      described_class.new(config: config).merge(openapi: [post]).skipped.first
    end

    it "has its own reason, not the one for an endpoint with nothing to send" do
      expect(outcome.reason).to eq(:mutating_not_allowed)
    end

    it "counts as declined rather than as a measurement gap" do
      expect(outcome).to be_declined
      expect(outcome).to be_inconclusive
    end

    # An endpoint we genuinely could not build a request for keeps the other reason.
    it "leaves no_example_available for the case it was named after" do
      bare = Loadwright::Discovery::Endpoint.new(path: "/api/v1/widgets", verb: :post, source: :route)
      config.allow_mutating_requests = true

      skipped = described_class.new(config: config).merge(route: [bare]).skipped.first

      expect(skipped.reason).to eq(:no_example_available)
      expect(skipped).not_to be_declined
    end
  end
end

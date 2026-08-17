# frozen_string_literal: true

RSpec.describe Loadwright::Execution::Transport::Null do
  let(:config) { Loadwright::Configuration.new }

  it "reports itself as the null transport, which CapabilityProfile keys on" do
    expect(described_class.new(config: config).name).to eq(:null)
  end

  describe "the dry-run guarantee" do
    # Layer 4's promise is that a dry run sends ZERO requests. Enforced by the
    # object raising rather than by a silent no-op, because a silently-skipped
    # request makes the guarantee untestable from the outside — which is exactly
    # what production-safety.md's testing requirement rules out ("assert on the
    # HTTP client/adapter directly, not just on output text").
    it "raises rather than quietly skipping when asked to issue during a dry run" do
      transport = described_class.new(config: config, dry_run: true)

      expect { transport.issue(build_request) }
        .to raise_error(Loadwright::Execution::Transport::Base::DryRunViolation, /zero requests/)
    end

    it "records nothing as issued after refusing" do
      transport = described_class.new(config: config, dry_run: true)

      begin
        transport.issue(build_request)
      rescue Loadwright::Execution::Transport::Base::DryRunViolation
        nil
      end

      expect(transport.issued_count).to eq(0)
    end
  end

  describe "scripted responses" do
    it "returns a 200 with an empty JSON array by default" do
      response = described_class.new(config: config).issue(build_request)

      expect(response.status).to eq(200)
      expect(response.body).to eq("[]")
      expect(response).to be_json
      expect(response.transport).to eq(:null)
    end

    it "scripts by endpoint key" do
      transport = described_class.new(
        config: config,
        responder: { "GET /api/v1/posts" => { status: 403, body: '{"error":"forbidden"}' } }
      )

      response = transport.issue(build_request(path: "/api/v1/posts"))

      expect(response.status).to eq(403)
      expect(response).not_to be_success
    end

    it "scripts with a callable, so a response can depend on the request" do
      transport = described_class.new(
        config: config,
        responder: ->(request) { { status: 200, body: JSON.generate(Array.new(request.query[:per_page].to_i, {})) } }
      )

      response = transport.issue(build_request(query: { per_page: 25 }))

      expect(JSON.parse(response.body).length).to eq(25)
    end

    # Needed so the resource guard's Tier 3 degradation check and the statistics
    # module are testable at all: real elapsed time here is effectively zero.
    it "honours a scripted latency" do
      transport = described_class.new(config: config, responder: { "GET /api/v1/posts" => { latency_ms: 250.0 } })

      expect(transport.issue(build_request).latency_ms).to eq(250.0)
    end

    it "scripts an exception, so the contention classifier is testable" do
      error = Class.new(StandardError).new("lock wait timeout")
      transport = described_class.new(config: config, responder: { "GET /api/v1/posts" => { error: error } })

      response = transport.issue(build_request)

      expect(response).to be_errored
      expect(response.error).to be(error)
      expect(response.status).to be_nil
    end
  end

  describe "#issued" do
    it "records every request, so a spec can assert on the adapter rather than on output" do
      transport = described_class.new(config: config)

      transport.issue(build_request(path: "/a"))
      transport.issue(build_request(path: "/b", verb: :post))

      expect(transport.issued.map(&:to_s)).to eq(["GET /a", "POST /b"])
    end
  end
end

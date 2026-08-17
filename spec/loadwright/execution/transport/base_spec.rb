# frozen_string_literal: true

RSpec.describe Loadwright::Execution::Transport::Base do
  let(:config) { Loadwright::Configuration.new }

  it "requires subclasses to name themselves, since CapabilityProfile keys on it" do
    expect { described_class.new(config: config).name }.to raise_error(NotImplementedError, /#name/)
  end

  it "requires subclasses to implement #perform" do
    transport = Class.new(described_class) { def name = :fake }.new(config: config)

    expect { transport.issue(build_request) }.to raise_error(NotImplementedError, /#perform/)
  end

  describe "error trapping" do
    # An exception from a request must come back as data, not unwind the run. The
    # resource guard has to classify it — a LockWaitTimeout is a contention event
    # routed to the guard, while an unexpected error is an endpoint error the
    # circuit breaker counts. Neither classification can happen if the exception
    # escapes.
    it "returns an errored RawResponse rather than raising" do
      transport = Class.new(described_class) do
        def name = :fake
        def perform(*) = raise ActiveRecordStub::LockWaitTimeout, "deadlock detected"
      end.new(config: config)
      stub_const("ActiveRecordStub::LockWaitTimeout", Class.new(StandardError))

      response = transport.issue(build_request)

      expect(response).to be_errored
      expect(response.error.message).to eq("deadlock detected")
      expect(response.status).to be_nil
      expect(response.latency_ms).to be >= 0
    end

    it "still records latency for a failed request, so a slow failure is visible" do
      transport = Class.new(described_class) do
        def name = :fake

        def perform(*)
          sleep 0.02
          raise "boom"
        end
      end.new(config: config)

      expect(transport.issue(build_request).latency_ms).to be >= 15
    end
  end

  describe "header merging" do
    it "layers request headers over config.default_headers" do
      config.default_headers = { "Accept" => "application/json", "X-Tenant" => "acme" }
      captured = nil
      transport = Class.new(described_class) do
        define_method(:name) { :fake }
        define_method(:perform) do |request, _started|
          captured = merged_headers(request)
          Loadwright::Execution::RawResponse.new(request: request, status: 200)
        end
      end.new(config: config)

      transport.issue(build_request(headers: { "X-Tenant" => "beta", "Authorization" => "Bearer x" }))

      expect(captured).to eq(
        "Accept" => "application/json", "X-Tenant" => "beta", "Authorization" => "Bearer x"
      )
    end
  end
end

# frozen_string_literal: true

require "action_dispatch"

RSpec.describe Loadwright::Execution::Transport::InProcess do
  let(:config) { Loadwright::Configuration.new }

  # ActionDispatch::Integration::Session drives any Rack app, so the transport can
  # be exercised without a Rails application. The full-stack case is covered by
  # the end-to-end run against examples/sample_app.
  let(:app) do
    lambda do |env|
      body = JSON.generate(
        "path" => env["PATH_INFO"],
        "query" => env["QUERY_STRING"],
        "method" => env["REQUEST_METHOD"],
        "correlation_id" => env["HTTP_X_LOADWRIGHT_REQUEST_ID"],
        "accept" => env["HTTP_ACCEPT"]
      )
      [200, { "content-type" => "application/json" }, [body]]
    end
  end

  subject(:transport) { described_class.new(config: config, app: app) }

  it "reports itself as the in-process transport" do
    expect(transport.name).to eq(:in_process)
  end

  # hide_const rather than relying on Rails being absent: examples/sample_app boots
  # a real Rails application, so whether `Rails` is defined here depends on spec
  # ORDER. A premise that depends on order is worse than no premise.
  it "refuses to start without an application to drive" do
    hide_const("Rails")

    expect { described_class.new(config: config).start! }
      .to raise_error(Loadwright::ServerError, /no Rails application/)
  end

  describe "#issue" do
    it "drives the full Rack stack and returns a RawResponse" do
      response = transport.issue(build_request(path: "/api/v1/posts"))

      expect(response.status).to eq(200)
      expect(response.transport).to eq(:in_process)
      expect(JSON.parse(response.body)).to include("path" => "/api/v1/posts", "method" => "GET")
      expect(response.latency_ms).to be >= 0
    end

    it "sends the query string as part of the path" do
      response = transport.issue(build_request(path: "/api/v1/posts", query: { per_page: 25, page: 2 }))

      expect(JSON.parse(response.body)["query"]).to eq("per_page=25&page=2")
    end

    # The correlation header goes through in BOTH transports, identically. If it
    # were only sent over the wire, the two modes' correlation paths would diverge
    # and the :in_process one would be untested.
    it "sends the correlation header, so both transports share one correlation path" do
      request = build_request
      response = transport.issue(request)

      expect(JSON.parse(response.body)["correlation_id"]).to eq(request.request_id)
    end

    it "applies config.default_headers" do
      response = transport.issue(build_request)

      expect(JSON.parse(response.body)["accept"]).to eq("application/json")
    end
  end

  describe "session isolation" do
    # ActionDispatch's session carries cookies and last-response state. One shared
    # across concurrent threads interleaves two requests' state, which surfaces as
    # a status code attributed to the wrong request — plausible, and wrong.
    it "gives each thread its own session" do
      slow_app = lambda do |env|
        sleep 0.02 if env["PATH_INFO"] == "/slow"
        [env["PATH_INFO"] == "/slow" ? 201 : 200, { "content-type" => "text/plain" }, [env["PATH_INFO"]]]
      end
      transport = described_class.new(config: config, app: slow_app)

      results = Queue.new
      threads = [
        Thread.new { results << transport.issue(build_request(path: "/slow")) },
        Thread.new { results << transport.issue(build_request(path: "/fast")) }
      ]
      threads.each(&:join)

      by_path = 2.times.map { results.pop }.to_h { |r| [r.body, r.status] }
      expect(by_path).to eq("/slow" => 201, "/fast" => 200)
    end
  end
end

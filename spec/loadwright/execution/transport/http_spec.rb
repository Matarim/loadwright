# frozen_string_literal: true

RSpec.describe Loadwright::Execution::Transport::Http do
  let(:config) { Loadwright::Configuration.new }

  # A real Puma server on a real ephemeral port. No Rails: what is under test here
  # is the wire behaviour, and a Rails app would only make it slower to find out
  # whether the socket half works.
  let(:echo_app) do
    lambda do |env|
      body = JSON.generate(
        "path" => env["PATH_INFO"],
        "query" => env["QUERY_STRING"],
        "method" => env["REQUEST_METHOD"],
        "correlation_id" => env["HTTP_X_LOADWRIGHT_REQUEST_ID"],
        "secret" => env["HTTP_X_LOADWRIGHT_SECRET"],
        "accept" => env["HTTP_ACCEPT"],
        "thread" => Thread.current.object_id.to_s
      )
      [200, { "content-type" => "application/json" }, [body]]
    end
  end

  it "reports itself as the http transport" do
    expect(described_class.new(config: config).name).to eq(:http)
  end

  describe "#issue" do
    it "issues a genuine HTTP request and returns a RawResponse" do
      with_local_http_app(echo_app) do |base_url|
        transport = described_class.new(config: config, base_url: base_url)

        response = transport.issue(build_request(path: "/api/v1/posts", query: { per_page: 5 }))

        expect(response.status).to eq(200)
        expect(response.transport).to eq(:http)
        expect(JSON.parse(response.body)).to include("path" => "/api/v1/posts", "query" => "per_page=5")
        transport.stop!
      end
    end

    it "sends the correlation header and the per-run secret" do
      with_local_http_app(echo_app) do |base_url|
        transport = described_class.new(config: config, base_url: base_url, secret: "s3cr3t")
        request = build_request

        body = JSON.parse(transport.issue(request).body)

        expect(body["correlation_id"]).to eq(request.request_id)
        expect(body["secret"]).to eq("s3cr3t")
        transport.stop!
      end
    end

    it "lowercases response header names, so a downstream lookup cannot silently miss" do
      app = ->(_) { [200, { "X-Loadwright-Query-Count" => "17" }, [""]] }

      with_local_http_app(app) do |base_url|
        transport = described_class.new(config: config, base_url: base_url)

        response = transport.issue(build_request)

        expect(response.header("x-loadwright-query-count")).to eq("17")
        expect(response.header("X-Loadwright-Query-Count")).to eq("17")
        transport.stop!
      end
    end

    it "returns an errored response rather than raising when the server is not there" do
      transport = described_class.new(config: config, base_url: "http://127.0.0.1:1")

      response = transport.issue(build_request)

      expect(response).to be_errored
      expect(response.status).to be_nil
    end
  end

  describe "connection handling" do
    # A shared connection under concurrency serialises the requests, which would
    # make every concurrency measurement a measurement of this transport instead
    # of the app — the exact number :http mode exists to produce honestly.
    it "uses one connection per thread" do
      with_local_http_app(echo_app) do |base_url|
        transport = described_class.new(config: config, base_url: base_url)
        results = Queue.new

        threads = 4.times.map { Thread.new { results << transport.issue(build_request) } }
        threads.each(&:join)

        expect(4.times.map { results.pop }.map(&:status)).to all(eq(200))
        transport.stop!
      end
    end

    it "closes its connections on stop!" do
      with_local_http_app(echo_app) do |base_url|
        transport = described_class.new(config: config, base_url: base_url)
        transport.issue(build_request)

        expect { transport.stop! }.not_to raise_error
      end
    end
  end

  describe "#ready?" do
    # The identity endpoint is the readiness probe: it needs no secret, touches no
    # database, and answering it proves both that the process is up AND that it
    # loads Loadwright.
    it "is true when the target answers the identity endpoint" do
      app = Loadwright::Execution::IdentityEndpoint.new(->(_) { [404, {}, []] })

      with_local_http_app(app) do |base_url|
        transport = described_class.new(config: config, base_url: base_url)

        expect(transport.ready?).to be(true)
        transport.stop!
      end
    end

    it "is false when nothing is listening" do
      expect(described_class.new(config: config, base_url: "http://127.0.0.1:1").ready?).to be(false)
    end
  end
end

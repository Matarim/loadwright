# frozen_string_literal: true

RSpec.describe Loadwright::Execution::CollectorMiddleware do
  let(:config) { Loadwright::Configuration.new }
  let(:tracker) { Loadwright::Instrumentation::QueryTracker.new(config: config) }

  after do
    described_class.unmount!
    tracker.stop!
  end

  # An app that issues a scripted number of "queries" per request, so attribution
  # can be checked without a database.
  def query_app(per_request: 3, delay: 0)
    lambda do |env|
      count = Integer(env["QUERY_STRING"].to_s[/queries=(\d+)/, 1] || per_request)
      sleep delay if delay.positive?
      count.times { |i| emit_sql("SELECT * FROM posts WHERE id = #{i}", duration: 0) }
      [200, { "content-type" => "application/json" }, [JSON.generate("path" => env["PATH_INFO"])]]
    end
  end

  def rack_env(path:, request_id: nil, secret: nil, remote: "127.0.0.1", query: "")
    env = {
      "PATH_INFO" => path, "REQUEST_METHOD" => "GET", "QUERY_STRING" => query,
      "REMOTE_ADDR" => remote
    }
    env["HTTP_X_LOADWRIGHT_REQUEST_ID"] = request_id if request_id
    env["HTTP_X_LOADWRIGHT_SECRET"] = secret if secret
    env
  end

  describe ".mount!" do
    # The security requirement that has no override. This endpoint exposes SQL,
    # call sites, and timing from the app under test — unlike the identity
    # endpoint, which exposes three static fields.
    it "refuses to mount when the guard flagged the environment as production-adjacent" do
      guard = build_guard(config: config, env: { "RAILS_ENV" => "production" })

      expect { described_class.mount!(tracker: tracker, guard: guard) }
        .to raise_error(Loadwright::SafetyError, /production-adjacent/)
      expect(described_class).not_to be_mounted
    end

    it "mounts for an ordinary dev run and returns a per-run secret" do
      guard = build_guard(config: config, env: { "RAILS_ENV" => "development" })

      secret = described_class.mount!(tracker: tracker, guard: guard)

      expect(secret.length).to be >= 32
      expect(described_class).to be_mounted
    end

    it "generates a different secret per run" do
      first = described_class.mount!(tracker: tracker)
      described_class.unmount!
      second = described_class.mount!(tracker: tracker)

      expect(first).not_to eq(second)
    end

    it "is unmounted after the run, so the endpoint stops existing" do
      described_class.mount!(tracker: tracker)
      described_class.unmount!

      expect(described_class).not_to be_mounted
    end
  end

  describe "correlation" do
    before do
      tracker.start!
      described_class.mount!(tracker: tracker)
    end

    it "attaches a query count header for a correlated request" do
      middleware = described_class.new(query_app(per_request: 4))

      _, headers, = middleware.call(rack_env(path: "/api/v1/posts", request_id: "req-1"))

      expect(headers[described_class::QUERY_COUNT_HEADER]).to eq("4")
    end

    it "attaches a distinct-query count, which is what makes duplicates visible" do
      app = lambda do |_env|
        3.times { emit_sql("SELECT * FROM comments WHERE post_id = 7", duration: 0) }
        emit_sql("SELECT * FROM posts", duration: 0)
        [200, {}, [""]]
      end
      middleware = described_class.new(app)

      _, headers, = middleware.call(rack_env(path: "/x", request_id: "req-1"))

      expect(headers[described_class::QUERY_COUNT_HEADER]).to eq("4")
      expect(headers[described_class::DISTINCT_QUERY_HEADER]).to eq("2")
    end

    # Otherwise the next request served by this Puma thread inherits the marker, and
    # its queries are attributed to a request that already finished.
    it "clears the request marker even when the app raises" do
      middleware = described_class.new(->(_) { raise "controller blew up" })

      expect { middleware.call(rack_env(path: "/x", request_id: "req-1")) }
        .to raise_error("controller blew up")
      expect(Loadwright::Instrumentation::CurrentRequest.id).to be_nil
    end

    it "passes an uncorrelated request straight through without headers" do
      middleware = described_class.new(query_app)

      _, headers, = middleware.call(rack_env(path: "/api/v1/posts"))

      expect(headers).not_to have_key(described_class::QUERY_COUNT_HEADER)
    end

    it "adds nothing when not mounted, so a stray header cannot instrument anything" do
      described_class.unmount!
      middleware = described_class.new(query_app)

      _, headers, = middleware.call(rack_env(path: "/x", request_id: "req-1"))

      expect(headers).not_to have_key(described_class::QUERY_COUNT_HEADER)
    end
  end

  # The requirement from execution-modes.md: "a spec proving request-ID
  # correlation returns the correct per-request metrics under concurrent load (the
  # obvious failure mode is cross-request metric bleed — test it deliberately with
  # overlapping requests)."
  #
  # Over a real socket, through real Puma threads, with deliberately overlapping
  # requests of DIFFERENT query counts — so a bleed shows up as a wrong number
  # rather than as a coincidentally-equal one.
  describe "no cross-request metric bleed over real HTTP under concurrency" do
    it "returns each request's own query count" do
      tracker.start!
      described_class.mount!(tracker: tracker)
      app = described_class.new(query_app(delay: 0.05))

      with_local_http_app(app) do |base_url|
        transport = Loadwright::Execution::Transport::Http.new(config: config, base_url: base_url)
        expected = { 2 => nil, 9 => nil, 17 => nil, 31 => nil }
        results = Queue.new

        threads = expected.keys.map do |count|
          Thread.new do
            response = transport.issue(build_request(path: "/api/v1/posts", query: { queries: count }))
            results << [count, response.header(described_class::QUERY_COUNT_HEADER)]
          end
        end
        threads.each(&:join)
        transport.stop!

        actual = expected.keys.length.times.map { results.pop }.to_h

        expect(actual).to eq(expected.keys.to_h { |c| [c, c.to_s] }),
                          "cross-request metric bleed: #{actual.inspect}"
      end
    end
  end

  describe "the collection endpoint" do
    let(:secret) { described_class.mount!(tracker: tracker) }

    before do
      tracker.start!
      secret
      tracker.begin_request("req-1")
      emit_sql("SELECT * FROM posts WHERE id = 1", duration: 0)
      emit_sql("SELECT * FROM posts WHERE id = 2", duration: 0)
      tracker.end_request("req-1")
    end

    def collect(request_id: "req-1", secret_header: nil, remote: "127.0.0.1")
      described_class.new(->(_) { raise "should not reach the app" }).call(
        rack_env(path: described_class::COLLECTION_PATH, secret: secret_header || secret,
                 remote: remote, query: "request_id=#{request_id}")
      )
    end

    it "returns the detail for a known request id" do
      status, _, body = collect

      payload = JSON.parse(body.join)
      expect(status).to eq(200)
      expect(payload["query_count"]).to eq(2)
      # Both queries share a fingerprint: that is what makes this an N+1 signature.
      expect(payload["distinct_query_count"]).to eq(1)
      expect(payload["queries"].length).to eq(2)
    end

    it "requires the per-run secret" do
      expect(collect(secret_header: "wrong-but-same-length-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa").first).to eq(403)
      expect(collect(secret_header: "short").first).to eq(403)
    end

    # Bound to localhost. A remote peer cannot reach this even holding the secret.
    it "refuses a non-loopback peer even with the correct secret" do
      expect(collect(remote: "10.0.0.7").first).to eq(403)
    end

    it "404s when not mounted, so the endpoint does not exist outside a run" do
      described_class.unmount!

      expect(collect.first).to eq(404)
    end

    it "404s for an unknown request id rather than returning an empty result" do
      expect(collect(request_id: "never-existed").first).to eq(404)
    end

    it "requires a request id" do
      status, _, body = described_class.new(->(_) { raise }).call(
        rack_env(path: described_class::COLLECTION_PATH, secret: secret)
      )

      expect(status).to eq(400)
      expect(JSON.parse(body.join)["error"]).to match(/request_id/)
    end

    # Redaction at COLLECTION time, not render time. Bind values never reach a
    # response body, so they cannot leak into a persisted run record either.
    it "returns fingerprints only, never raw SQL or bind values" do
      _, _, body = collect

      serialised = body.join
      expect(serialised).to include("SELECT * FROM posts WHERE id = ?")
      expect(serialised).not_to include("id = 1")
      expect(serialised).not_to include("id = 2")
      expect(JSON.parse(serialised)["queries"].first.keys)
        .to contain_exactly("fingerprint", "duration_ms", "name", "call_site")
    end

    it "releases the bucket after collection, so a long run does not grow forever" do
      collect

      expect(tracker.bucket("req-1")).to be_nil
    end
  end
end

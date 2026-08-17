# frozen_string_literal: true

RSpec.describe Loadwright::Execution::IdentityEndpoint do
  def rack_env(path: described_class::PATH, method: "GET")
    { "PATH_INFO" => path, "REQUEST_METHOD" => method }
  end

  def parsed_body(response)
    JSON.parse(response[2].join)
  end

  describe "the payload" do
    # The assertion that keeps this endpoint safe over time. It is UNGUARDED —
    # no secret, mounted whenever the gem is loaded — so its payload must never
    # grow into the collection endpoint's. Asserting on the exact key set means a
    # future addition fails here rather than quietly shipping.
    it "exposes exactly the environment name, the version, and the enabled flag" do
      response = described_class.new.call(rack_env)

      expect(parsed_body(response).keys.sort).to eq(described_class::PAYLOAD_KEYS.sort)
    end

    it "returns nothing resembling SQL, stack traces, bind values, or timing" do
      body = described_class.new.call(rack_env)[2].join

      %w[sql query stack backtrace binds duration runtime allocations config routes].each do |leak|
        expect(body.downcase).not_to include(leak)
      end
    end

    it "reports the current environment" do
      payload = described_class.payload

      expect(payload["env"]).to eq(described_class.current_environment.to_s)
      expect(payload["loadwright_version"]).to eq(Loadwright::VERSION)
    end

    # enabled_here is a courtesy for whoever reads the response by hand. The
    # asking side treats the whole report as authoritative for refusal only, so
    # nothing downstream depends on this being true.
    it "says whether Loadwright would consent to run in this process" do
      config = Loadwright::Configuration.new
      config.enabled_environments = [described_class.current_environment.to_sym]

      expect(described_class.payload(config: config)["enabled_here"]).to be(true)

      config.enabled_environments = [:nowhere]
      expect(described_class.payload(config: config)["enabled_here"]).to be(false)
    end
  end

  describe "as Rack middleware" do
    it "answers the identity path itself" do
      status, headers, = described_class.new(->(_) { raise "should not reach the app" }).call(rack_env)

      expect(status).to eq(200)
      expect(headers["content-type"]).to eq("application/json")
    end

    it "does not cache, so a redeployed target cannot answer with a stale environment" do
      _, headers, = described_class.new.call(rack_env)

      expect(headers["cache-control"]).to eq("no-store")
    end

    it "answers HEAD as well as GET, since a probe may use either" do
      expect(described_class.new.call(rack_env(method: "HEAD")).first).to eq(200)
    end

    it "passes every other path through untouched" do
      downstream = ->(env) { [204, {}, [env["PATH_INFO"]]] }

      expect(described_class.new(downstream).call(rack_env(path: "/api/v1/posts")))
        .to eq([204, {}, ["/api/v1/posts"]])
    end

    it "ignores non-idempotent verbs on its own path" do
      downstream = ->(_) { [204, {}, []] }

      expect(described_class.new(downstream).call(rack_env(method: "POST")).first).to eq(204)
    end
  end
end

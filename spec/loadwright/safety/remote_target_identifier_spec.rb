# frozen_string_literal: true

RSpec.describe Loadwright::Safety::RemoteTargetIdentifier do
  let(:config) { Loadwright::Configuration.new }

  def identifier(&fetcher)
    described_class.new(config: config, fetcher: fetcher || ->(*) { raise "no fetcher scripted" })
  end

  def identity_json(env:, version: Loadwright::VERSION, enabled: true)
    JSON.generate("env" => env, "loadwright_version" => version, "enabled_here" => enabled)
  end

  describe "the request it makes" do
    it "asks the unguarded identity path, not the guarded collection endpoint" do
      asked = nil
      identifier { |uri, _timeout| asked = uri; identity_json(env: "development") }
        .identify!("http://staging.example.com/api/v1?x=1#frag")

      expect(asked.path).to eq(Loadwright::Execution::IdentityEndpoint::PATH)
      expect(asked.query).to be_nil
      expect(asked.fragment).to be_nil
      expect(asked.host).to eq("staging.example.com")
    end

    it "uses a short timeout, because a slow answer is not a trustworthy one" do
      timeout = nil
      described_class.new(config: config, fetcher: lambda { |_uri, t|
        timeout = t
        identity_json(env: "development")
      }).identify!("http://staging.example.com")

      expect(timeout).to eq(described_class::DEFAULT_TIMEOUT)
    end

    it "refuses a target URL it cannot resolve to a host" do
      expect { identifier.identify!("not a url") }
        .to raise_error(Loadwright::SafetyError, /could not be parsed/)
      expect { identifier.identify!("/relative/path") }
        .to raise_error(Loadwright::SafetyError, /is not an http\(s\) URL/)
    end
  end

  describe "asymmetric trust" do
    # The direction people expect.
    it "hard-refuses an environment outside enabled_environments" do
      subject = identifier { identity_json(env: "production") }

      expect { subject.identify!("http://api.acme.com") }
        .to raise_error(Loadwright::SafetyError) { |error|
              expect(error.message).to include('"production"')
              expect(error.message).to include("no override for this")
            }
    end

    it "hard-refuses even a plausible-sounding non-allowlisted environment" do
      subject = identifier { identity_json(env: "staging") }

      expect { subject.identify!("http://staging.acme.com") }
        .to raise_error(Loadwright::SafetyError, /enabled_environments/)
    end

    # The direction people get wrong. This returns a report, and the report is
    # not a permission — the guard's spec proves every Layer 3 condition still
    # applies afterwards.
    it "returns a report, not a boolean, for an allowed environment" do
      report = identifier { identity_json(env: "development") }.identify!("http://staging.example.com")

      expect(report).to be_a(described_class::Report)
      expect(report.environment).to eq("development")
      expect(report.to_h).to include(host: "staging.example.com", environment: "development")
    end

    it "respects a widened allowlist in the asking process" do
      config.enabled_environments = %i[development test qa]

      expect(identifier { identity_json(env: "qa") }.identify!("http://qa.acme.com").environment).to eq("qa")
    end
  end

  describe "fail-closed cases" do
    {
      "a refused connection" => -> { raise Errno::ECONNREFUSED, "connect(2)" },
      "a timeout" => -> { raise Timeout::Error, "execution expired" },
      "a non-2xx status" => -> { raise "HTTP 404" },
      "TLS failure" => -> { raise OpenSSL::SSL::SSLError, "certificate verify failed" }
    }.each do |description, raiser|
      it "refuses on #{description}" do
        subject = identifier { raiser.call }

        expect { subject.identify!("http://staging.example.com") }
          .to raise_error(Loadwright::SafetyError, /identity/)
      end
    end

    {
      "an HTML error page" => "<html><body>502 Bad Gateway</body></html>",
      "an empty body" => "",
      "a JSON array" => "[]",
      "a JSON object with no env field" => '{"loadwright_version":"0.0.1"}',
      "an empty env field" => '{"env":""}'
    }.each do |description, body|
      it "refuses on #{description}" do
        subject = identifier { body }

        expect { subject.identify!("http://staging.example.com") }
          .to raise_error(Loadwright::SafetyError, /would not identify itself|did not answer/)
      end
    end
  end

  describe "what a target cannot do" do
    # The one-way ratchet, asserted directly: there is no answer that unlocks
    # anything. Every response either produces a report that grants nothing, or
    # a refusal.
    it "never returns anything that reads as an approval" do
      answers = [
        identity_json(env: "development", enabled: true),
        identity_json(env: "test", enabled: true),
        # A target claiming to be enabled while naming a disallowed environment.
        identity_json(env: "production", enabled: true),
        '{"env":"development","enabled_here":true,"allow_production":true,"approved":true}'
      ]

      results = answers.map do |body|
        identifier { body }.identify!("http://staging.example.com")
      rescue Loadwright::SafetyError
        :refused
      end

      expect(results).to all(satisfy { |r| r == :refused || r.is_a?(described_class::Report) })
      expect(results.grep(described_class::Report)).to all(satisfy { |r| !r.respond_to?(:approved) })
    end
  end
end

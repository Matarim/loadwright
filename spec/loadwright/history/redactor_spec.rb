# frozen_string_literal: true

RSpec.describe Loadwright::History::Redactor do
  let(:config) { Loadwright::Configuration.new }

  subject(:redactor) { described_class.new(config: config) }

  describe "#headers" do
    it "filters the shipped default patterns" do
      result = redactor.headers(
        "Authorization" => "Bearer sk-live-abc",
        "Cookie" => "session=xyz",
        "X-Api-Key" => "k-123",
        "Accept" => "application/json"
      )

      expect(result).to eq(
        "Authorization" => "[FILTERED]",
        "Cookie" => "[FILTERED]",
        "X-Api-Key" => "[FILTERED]",
        "Accept" => "application/json"
      )
    end

    it "honours user-configured extra patterns" do
      config.redact_additional_patterns = [/x-tenant-secret/i]

      expect(redactor.headers("X-Tenant-Secret" => "abc")).to eq("X-Tenant-Secret" => "[FILTERED]")
    end

    it "tolerates no headers" do
      expect(redactor.headers(nil)).to eq({})
    end
  end

  describe "#params" do
    # The sensitive key is nested far more often than top-level:
    # `user: { password: }` rather than a bare `password`.
    it "recurses into nested hashes and arrays" do
      result = redactor.params(
        "title" => "ok",
        "user" => { "email" => "a@b.com", "password" => "hunter2" },
        "cards" => [{ "token" => "tok_live_1" }]
      )

      expect(result).to eq(
        "title" => "ok",
        "user" => { "email" => "a@b.com", "password" => "[FILTERED]" },
        "cards" => [{ "token" => "[FILTERED]" }]
      )
    end

    it "matches on substrings, since real apps name things password_confirmation" do
      expect(redactor.params("password_confirmation" => "x")).to eq("password_confirmation" => "[FILTERED]")
      expect(redactor.params("client_secret" => "x")).to eq("client_secret" => "[FILTERED]")
    end

    # Over-redaction that hides a real value is its own kind of misleading report,
    # so the parameter filters are deliberately NOT derived from the header
    # patterns — /cookie/ as a parameter filter would redact a legitimate
    # cookie_consent boolean.
    it "does not redact a parameter that merely resembles a sensitive header" do
      expect(redactor.params("cookie_consent" => true)).to eq("cookie_consent" => true)
    end

    it "leaves non-hash values alone" do
      expect(redactor.params("a string")).to eq("a string")
      expect(redactor.params(42)).to eq(42)
      expect(redactor.params(nil)).to be_nil
    end
  end

  describe "#path" do
    # /reset/abc123?token=xyz is a real shape, and a URL is not somewhere people
    # look for secrets.
    it "filters a sensitive query value while keeping the path readable" do
      expect(redactor.path("/api/v1/posts?api_key=abc123&per_page=25"))
        .to eq("/api/v1/posts?api_key=[FILTERED]&per_page=25")
    end

    it "filters several sensitive values in one query string" do
      result = redactor.path("/x?token=a&password=b&page=2")

      expect(result).to include("token=[FILTERED]", "password=[FILTERED]", "page=2")
    end

    it "leaves a clean path untouched" do
      expect(redactor.path("/api/v1/posts/42/comments")).to eq("/api/v1/posts/42/comments")
    end

    it "tolerates nil" do
      expect(redactor.path(nil)).to be_nil
    end
  end

  describe "the host app's own filter_parameters" do
    # An app has already told Rails which of ITS parameters are sensitive.
    # Duplicating that list here would drift from it immediately.
    it "adopts them when honor_rails_filter_parameters is on" do
      stub_rails_filter_parameters(%i[ssn internal_ref])

      result = redactor.params("ssn" => "123-45-6789", "internal_ref" => "X1", "title" => "ok")

      expect(result).to eq("ssn" => "[FILTERED]", "internal_ref" => "[FILTERED]", "title" => "ok")
    end

    it "accepts regexp entries as well as symbols" do
      stub_rails_filter_parameters([/\Aacct_/])

      expect(redactor.params("acct_number" => "1")).to eq("acct_number" => "[FILTERED]")
    end

    it "ignores them when the user turned that off" do
      config.honor_rails_filter_parameters = false
      stub_rails_filter_parameters(%i[ssn])

      expect(redactor.params("ssn" => "123")).to eq("ssn" => "123")
    end

    def stub_rails_filter_parameters(list)
      app_config = Struct.new(:filter_parameters).new(list)
      application = Struct.new(:config).new(app_config)
      rails = Module.new
      rails.define_singleton_method(:respond_to?) { |name, *| name == :application }
      rails.define_singleton_method(:application) { application }
      stub_const("Rails", rails)
    end
  end

  describe "#to_h" do
    # Which redaction was in effect is part of reading a run record honestly — and
    # INV-10 tells agents to check it before pasting a report anywhere.
    it "records what was and was not redacted, for the report metadata" do
      audit = redactor.to_h

      expect(audit).to include(
        honors_rails_filter_parameters: true,
        sql_bind_values_redacted: true,
        response_bodies_included: false
      )
      expect(audit[:header_patterns]).to include("/authorization/i")
    end
  end

  # THE TWO PLACES REDACTION HAS TO REACH THAT ARE NOT OBVIOUS.
  #
  # Measurement.unavailable(reason) and CapabilityProfile's downgrade causes read as
  # internal metadata, so it is easy to treat them as exempt. They are free text
  # written by the code that failed, which knows exactly the things worth protecting --
  # the target URL, the database host, the path the secret was at -- and they are
  # persisted into every run record and rendered into every report.
  describe "#reason" do
    it "redacts a non-loopback host, which can name internal infrastructure" do
      expect(redactor.reason("the app under test at http://staging.acme.internal:3000 did not answer"))
        .to eq("the app under test at http://[FILTERED]:3000 did not answer")
    end

    # The whole value of the message, and it names nothing private. Redacting it would
    # be over-redaction that hides why a signal is missing.
    it "keeps a loopback host, which is the useful half of a local failure" do
      text = "the app at http://127.0.0.1:52341 did not become healthy"

      expect(redactor.reason(text)).to eq(text)
    end

    it "redacts credentials embedded in a connection string" do
      result = redactor.reason("could not connect to postgres://app:hunter2@db.acme.internal/production")

      expect(result).not_to include("hunter2")
      expect(result).not_to include("db.acme.internal")
    end

    # A home directory names the user. The path is the useful part; the account is not.
    it "replaces the home directory with ~" do
      expect(redactor.reason("could not read #{Dir.home}/tmp/loadwright/x.secret"))
        .to eq("could not read ~/tmp/loadwright/x.secret")
    end

    it "redacts a secret assigned inside free text" do
      expect(redactor.reason("the auth token=sk-live-abc123 was rejected"))
        .to eq("the auth token=[FILTERED] was rejected")
    end

    # Over-redaction is its own failure: a reason that no longer says why a signal is
    # missing is worse than no reason, because it looks like an answer.
    it "leaves an ordinary mention of a sensitive word alone" do
      text = "no auth token was configured, so every request was anonymous"

      expect(redactor.reason(text)).to eq(text)
    end

    it "tolerates nil" do
      expect(redactor.reason(nil)).to be_nil
    end
  end

  # One entry point for anything persisted, so a field added downstream is covered by
  # default rather than by someone remembering to redact it.
  describe "#document" do
    it "redacts reason strings wherever they appear in the structure" do
      result = redactor.document(
        endpoints: [
          { endpoint: "GET /a",
            latency: { p99: { unavailable: "the app at http://prod.acme.internal timed out" } } }
        ]
      )

      expect(result[:endpoints].first[:latency][:p99][:unavailable]).to include("[FILTERED]")
    end

    it "redacts a capability downgrade cause" do
      timeline = Loadwright::CapabilityTimeline.new(
        Loadwright::CapabilityProfile.derive(transport: :http, collector: :middleware)
      )
      timeline.degrade!(:n_plus_one_slope, reason: "http://collector.acme.internal stopped answering")

      result = redactor.document(timeline.to_h)

      expect(JSON.generate(result)).not_to include("collector.acme.internal")
    end

    # The exemplar statement is kept for EXPLAIN and has its literals intact. Nothing in
    # a report is built from it -- the fingerprint is -- so it must not reach an
    # artefact at all.
    it "drops raw SQL outright rather than trying to sanitise it" do
      result = redactor.document(
        queries: [{ fingerprint: "SELECT * FROM users WHERE email = ?",
                    sql: "SELECT * FROM users WHERE email = 'ceo@acme.com'" }]
      )

      expect(result[:queries].first).to eq(fingerprint: "SELECT * FROM users WHERE email = ?")
      expect(JSON.generate(result)).not_to include("ceo@acme.com")
    end

    it "still filters sensitive keys anywhere in the tree" do
      result = redactor.document(metadata: { config: { auth_token_provider: "sk-live-abc" } })

      expect(result[:metadata][:config][:auth_token_provider]).to eq("[FILTERED]")
    end

    it "leaves ordinary values untouched" do
      expect(redactor.document(summary: { endpoints: 4, healthy: 2 }))
        .to eq(summary: { endpoints: 4, healthy: 2 })
    end
  end
end

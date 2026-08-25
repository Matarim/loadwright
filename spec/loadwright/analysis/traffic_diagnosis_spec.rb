# frozen_string_literal: true

# performance-signals.md Part 6. The validity gate is right to mark a 429 or a 403
# `inconclusive`, but a first-time user whose token is not wired up gets a report where
# EVERY endpoint is inconclusive, each with an accurate reason and no explanation of
# the one thing that caused all of them. The pattern is only visible across endpoints.
RSpec.describe Loadwright::Analysis::TrafficDiagnosis do
  let(:config) { Loadwright::Configuration.new }

  subject(:diagnosis) { described_class.new(config: config) }

  def observations(map)
    map.transform_values do |value|
      value.is_a?(Hash) ? value : { statuses: Array(value), rate_limit_headers: {} }
    end
  end

  def kinds(map) = diagnosis.diagnose(observations(map)).map(&:kind)

  describe "rate limiting" do
    it "names a run that is being throttled" do
      result = diagnosis.diagnose(observations("GET /a" => [429, 429], "GET /b" => [200]))

      expect(result.map(&:kind)).to eq([:rate_limited])
    end

    # The user's next question is "what do I do", so the message has to answer it.
    it "says how to fix it rather than only that it happened" do
      message = diagnosis.diagnose(observations("GET /a" => [429], "GET /b" => [429])).first.message

      expect(message).to include("Allowlist Loadwright's requests")
      expect(message).to include("disable rate limiting for this environment")
    end

    it "warns that the measurements describe the limiter rather than the app" do
      message = diagnosis.diagnose(observations("GET /a" => [429], "GET /b" => [429])).first.message

      expect(message).to include("reflect the limiter, not the app")
    end

    # A limiter in log-only mode returns 200 and still sets the headers, which is a
    # warning worth giving before the run that trips it.
    it "detects a limiter from its headers even without a 429" do
      result = diagnosis.diagnose(
        "GET /a" => { statuses: [200], rate_limit_headers: { "ratelimit-remaining" => "0" } },
        "GET /b" => { statuses: [200], rate_limit_headers: {} }
      )

      expect(result.map(&:kind)).to eq([:rate_limited])
      expect(result.first.evidence[:headers_seen]).to eq(["ratelimit-remaining"])
    end

    it "says nothing about a run where nothing was limited" do
      expect(kinds("GET /a" => [200], "GET /b" => [200])).to be_empty
    end

    # One throttled endpoint out of twenty is not a throttled RUN, and telling the user
    # to reconfigure their limiter over it would be wrong advice.
    it "does not call a whole run throttled over one endpoint" do
      map = { "GET /a" => [429] }
      10.times { |i| map["GET /ok#{i}"] = [200] }

      expect(kinds(map)).to be_empty
    end
  end

  describe "auth misconfiguration" do
    let(:uniform_403) { { "GET /a" => [403], "GET /b" => [403], "GET /c" => [401], "GET /d" => [403] } }

    it "names a run where every endpoint refuses the identity" do
      expect(kinds(uniform_403)).to eq([:auth_misconfigured])
    end

    it "says this is almost always the token rather than the API" do
      message = diagnosis.diagnose(observations(uniform_403)).first.message

      expect(message).to include("almost always")
      expect(message).to include("Nothing below is a measurement of the app")
    end

    # "Your provider is returning a bad token" is unhelpful advice to someone who never
    # configured one, and that is the far more common first-run case.
    it "points at the provider not being configured when it is not" do
      config.auth_token_provider = nil

      expect(diagnosis.diagnose(observations(uniform_403)).first.message)
        .to include("not being configured at all")
    end

    it "points at the token itself when a provider IS configured" do
      config.auth_token_provider = -> { "token" }

      expect(diagnosis.diagnose(observations(uniform_403)).first.message)
        .to include("expired, wrong scope, or for a user that does not exist")
    end

    # THE FALSE POSITIVE TO AVOID. An API with an admin section is not a
    # misconfiguration, and telling someone their credentials are wrong when they are
    # not sends them to fix something that works.
    it "does not blame the token for one forbidden endpoint among many" do
      map = { "GET /admin" => [403] }
      10.times { |i| map["GET /ok#{i}"] = [200] }

      expect(kinds(map)).to be_empty
    end

    it "says nothing in a run too small for 'across endpoints' to mean anything" do
      expect(kinds("GET /a" => [403], "GET /b" => [403])).to be_empty
    end

    # A 403 mixed with 200s on the SAME endpoint is not a uniform failure -- the
    # identity clearly works sometimes.
    it "ignores an endpoint that only sometimes refuses" do
      map = { "GET /a" => [403, 200], "GET /b" => [403, 200], "GET /c" => [403, 200] }

      expect(kinds(map)).to be_empty
    end
  end

  # The diagnosis is not just advice: it upgrades the endpoint's `inconclusive` reason
  # to one whose stored explanation names the fix.
  describe "#reason_for" do
    it "labels a 429 endpoint :rate_limited without needing run-level agreement" do
      observation = { statuses: [429], rate_limit_headers: {} }

      expect(diagnosis.reason_for("GET /a", observation, [])).to eq(:rate_limited)
    end

    it "labels a 403 endpoint :auth_failed only when the run-level pattern supports it" do
      observation = { statuses: [403], rate_limit_headers: {} }
      diagnoses = diagnosis.diagnose(observations("GET /a" => [403], "GET /b" => [403], "GET /c" => [403]))

      expect(diagnosis.reason_for("GET /a", observation, diagnoses)).to eq(:auth_failed)
      expect(diagnosis.reason_for("GET /a", observation, [])).to be_nil
    end

    it "leaves an ordinary 500 to the validity gate's own reason" do
      observation = { statuses: [500], rate_limit_headers: {} }

      expect(diagnosis.reason_for("GET /a", observation, [])).to be_nil
    end

    # Both reasons exist on EndpointOutcome already, and their stored explanations are
    # the actionable half -- `:unsuccessful_status` only says an error path was measured.
    it "uses reasons EndpointOutcome knows how to explain" do
      %i[rate_limited auth_failed].each do |reason|
        expect(Loadwright::EndpointOutcome::REASONS).to have_key(reason)
      end
      expect(Loadwright::EndpointOutcome::REASONS[:auth_failed]).to include("auth_token_provider")
    end
  end
end

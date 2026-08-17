# frozen_string_literal: true

# AUTHENTICATION, AGAINST A REAL ENDPOINT THAT ACTUALLY CHECKS THE TOKEN.
#
# IdentityPool#resolve! was called from nowhere in lib/. A user configured
# auth_token_provider, the pool was built and handed to the runner, and the tokens
# were never resolved -- so `headers_for_next` returned {} and every request went out
# unauthenticated. The report then said "a uniform 401/403 almost always means
# auth_token_provider is unset or returning an invalid token", which was the tool
# blaming the user for its own omission, on the failure it documents as most common.
#
# No unit test caught it because the pool works perfectly in isolation, and no
# end-to-end test caught it because no fixture endpoint cared whether a token
# arrived. Both halves are fixed here: the run is real, and /api/v1/me 401s without
# a valid token.
RSpec.describe "authentication end to end", :sample_app do
  let(:stdout) { StringIO.new }

  let(:config) do
    Loadwright::Configuration.new.tap do |c|
      c.scale_factors = [2]
      c.page_size_sweep = [5]
      c.concurrency_levels = [1]
      c.requests_per_endpoint_per_level = 4
      c.warmup_requests = 0
      c.factory_map = { "post" => { factory: :post, trait: :with_comments } }
    end
  end

  def run_against_me!
    reset_sample_app!
    context = Loadwright::Execution::ExecutionContext.build_in_process(config: config, app: sample_app)
    seeder = Loadwright::Seeding::FactoryBotSeeder.new(config: config, stdout: stdout)
    context.start!

    result = Loadwright::Engine::LoadRunner.new(
      config: config, context: context, seeder: seeder,
      identities: Loadwright::Seeding::IdentityPool.new(config: config),
      resolver: Loadwright::Discovery::PathParamResolver.new(config: config), stdout: stdout
    ).run(endpoints: [Loadwright::Discovery::Endpoint.new(path: "/api/v1/me", verb: :get, source: :openapi)])

    context.stop!
    seeder.cleanup!
    result
  end

  def outcome(result) = result.outcomes.find { |o| o.endpoint.path == "/api/v1/me" }

  # The STATUSES, not the outcome state. At this sample size the endpoint is
  # inconclusive either way -- p50 needs 20 requests and this runs 4 -- and that is
  # correct behaviour about statistics, not about authentication. Asserting on the
  # outcome would pass for the wrong reason in one direction and fail for the wrong
  # reason in the other.
  def statuses(result) = result.cells_for("GET /api/v1/me").flat_map { |c| Array(c.statuses) }.uniq

  it "authenticates when a token provider is configured" do
    config.auth_token_provider = -> { "token-alice" }

    expect(statuses(run_against_me!)).to eq([200])
  end

  # The control. Without it the example above could pass against an endpoint that
  # never checked anything, which is exactly the hole this whole file plugs.
  it "is genuinely refused when no token is configured" do
    config.auth_token_provider = nil

    result = run_against_me!

    expect(statuses(result)).to eq([401])
    expect(outcome(result).reason).to eq(:unsuccessful_status)
  end

  # response-analysis.md wants multi-identity traffic: one identity gives identical
  # cache keys and single-tenant scoping, which can make a badly-scoped query look
  # correctly scoped.
  it "rotates across every identity the provider returns" do
    config.auth_token_provider = -> { %w[token-alice token-bob token-carol] }

    result = run_against_me!

    expect(statuses(result)).to eq([200])
    # Every one of them was actually used, not just the first.
    expect(result.metadata.dig(:identities, :identities)).to eq(3)
  end

  # THE LOGIN FLOW. The point of config.auth_login is that a user names the request
  # their own clients make instead of writing the code that mints a token inside their
  # initializer -- which for a session app means hand-assembling a cookie, and is a
  # large part of why unset or wrong auth is the most common first-run failure.
  describe "config.auth_login" do
    it "logs in and uses the token it was given" do
      config.auth_login = {
        path: "/api/v1/login",
        credentials: [{ email: "alice@example.com", password: "password" }],
        extract: { json: "token" }
      }

      expect(statuses(run_against_me!)).to eq([200])
    end

    it "logs in once per credential, so traffic is not single-identity" do
      config.auth_login = {
        path: "/api/v1/login",
        credentials: [
          { email: "alice@example.com", password: "password" },
          { email: "bob@example.com", password: "password" },
          { email: "carol@example.com", password: "password" }
        ],
        extract: { json: "token" }
      }

      result = run_against_me!

      expect(statuses(result)).to eq([200])
      expect(result.metadata.dig(:identities, :identities)).to eq(3)
    end

    # Session auth is the case auth_token_provider serves worst, because the user
    # would otherwise have to build a valid cookie by hand.
    it "can take the token out of a response header instead of the body" do
      config.auth_strategy = :session
      config.auth_login = {
        path: "/api/v1/login",
        credentials: [{ email: "alice@example.com", password: "password" }],
        extract: { header: "Set-Cookie" }
      }

      # The fixture's /me reads a Bearer token, so a cookie will not authenticate it.
      # What this proves is that the header was found and carried -- the run got a
      # token out of a header at all, rather than failing to extract one.
      run_against_me!

      expect(stdout.string).not_to include("no token was found")
    end

    # A wrong credential means every request in the run is unauthenticated. Stopping
    # is better than a wall of 401s that says nothing about the app.
    it "aborts with the status, and never echoes the credential back" do
      config.auth_login = {
        path: "/api/v1/login",
        credentials: [{ email: "alice@example.com", password: "wrong" }],
        extract: { json: "token" }
      }

      expect { run_against_me! }.to raise_error(Loadwright::SeedingError) { |error|
        expect(error.message).to include("answered 401")
        expect(error.message).not_to include("wrong")
      }
    end

    it "says which key is missing rather than failing at the first request" do
      config.auth_login = { path: "/api/v1/login" }

      expect { run_against_me! }
        .to raise_error(Loadwright::ConfigurationError, /missing credentials, extract/)
    end

    # Two answers to "where does the token come from" is a configuration the user
    # cannot reason about, so it is refused rather than resolved by precedence.
    it "refuses to be combined with auth_token_provider" do
      config.auth_login = { path: "/x", credentials: [{}], extract: { json: "t" } }
      config.auth_token_provider = -> { "token-alice" }

      expect { config.validate! }.to raise_error(Loadwright::ConfigurationError, /both set/)
    end
  end

  it "reports a single-identity provider as the limitation it is" do
    config.auth_token_provider = -> { "token-alice" }

    run_against_me!

    expect(stdout.string).to include("all traffic is one identity")
  end
end

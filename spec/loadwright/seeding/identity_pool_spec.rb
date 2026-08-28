# frozen_string_literal: true

RSpec.describe Loadwright::Seeding::IdentityPool do
  let(:config) { Loadwright::Configuration.new }

  subject(:pool) { described_class.new(config: config) }

  describe "#resolve!" do
    it "accepts a collection of tokens" do
      config.auth_token_provider = -> { %w[token-a token-b token-c] }

      pool.resolve!

      expect(pool.size).to eq(3)
      expect(pool.warnings).to be_empty
    end

    it "accepts a bare value rather than a callable" do
      config.auth_token_provider = "static-token"

      expect(pool.resolve!.size).to eq(1)
    end

    # Single-identity traffic lies three ways: identical cache keys, single-tenant
    # scoping, and row-lock contention on one user's rows. A badly-scoped query can
    # look correctly scoped this way, which is why this is a warning and not a
    # convenience.
    it "warns about a single token, naming what it distorts" do
      config.auth_token_provider = -> { "one-token" }

      pool.resolve!

      warning = pool.warnings.join
      expect(warning).to include("all traffic is one identity")
      expect(warning).to include("identical cache keys")
      expect(warning).to include("single-tenant scoping")
    end

    it "is a no-op for a genuinely public API with no provider" do
      pool.resolve!

      expect(pool).not_to be_resolved
      expect(pool.headers_for_next).to eq({})
    end

    # Every request would be unauthenticated and the whole run would report
    # inconclusive for a 401 — which says nothing about the endpoints. Aborting
    # with the verification command beats a report full of 403s.
    it "aborts when the provider returns nothing usable" do
      config.auth_token_provider = -> { [nil, ""] }

      expect { pool.resolve! }.to raise_error(Loadwright::SeedingError) { |error|
        expect(error.message).to include("no usable token")
        expect(error.message).to include("rails runner")
      }
    end

    it "aborts when the provider itself raises, naming the class" do
      config.auth_token_provider = -> { raise NoMethodError, "undefined method for nil" }

      expect { pool.resolve! }.to raise_error(Loadwright::SeedingError, /NoMethodError/)
    end

    # Calling the provider per request would make token issuance part of every
    # measurement — for a JWT issuer doing bcrypt work, a large part.
    it "calls the provider once, not per request" do
      calls = 0
      config.auth_token_provider = -> { calls += 1 and %w[a b] }

      pool.resolve!
      10.times { pool.headers_for_next }

      expect(calls).to eq(1)
    end
  end

  describe "#headers_for_next" do
    before { config.auth_token_provider = -> { %w[a b c] } }

    # Round-robin rather than random: a run must be reproducible, and a random
    # identity per request makes two runs incomparable for no benefit.
    it "rotates deterministically" do
      pool.resolve!

      tokens = 7.times.map { pool.headers_for_next["Authorization"] }

      expect(tokens).to eq([
                             "Bearer a", "Bearer b", "Bearer c",
                             "Bearer a", "Bearer b", "Bearer c", "Bearer a"
                           ])
    end

    {
      bearer_token: ["Authorization", "Bearer a"],
      session: ["Cookie", "a"],
      header: ["X-Api-Key", "a"]
    }.each do |strategy, (header, value)|
      it "builds the right header for #{strategy}" do
        config.auth_strategy = strategy
        pool.resolve!

        expect(pool.headers_for_next).to eq(header => value)
      end
    end

    it "refuses an unknown strategy rather than sending an unauthenticated request" do
      config.auth_strategy = :telepathy
      pool.resolve!

      expect { pool.headers_for_next }
        .to raise_error(Loadwright::ConfigurationError, /unknown auth_strategy/)
    end

    it "rotates safely from several threads at once" do
      pool.resolve!
      results = Queue.new

      threads = 6.times.map { Thread.new { 50.times { results << pool.headers_for_next["Authorization"] } } }
      threads.each(&:join)

      tally = 300.times.map { results.pop }.tally
      expect(tally.values.sum).to eq(300)
      expect(tally.keys.sort).to eq(["Bearer a", "Bearer b", "Bearer c"])
    end
  end

  describe "#to_h" do
    it "records the identity spread for the report, since it changes how to read the numbers" do
      config.auth_token_provider = -> { "solo" }
      pool.resolve!

      expect(pool.to_h).to include(strategy: :bearer_token, identities: 1, configured: true)
      expect(pool.to_h[:warnings].join).to include("one identity")
    end
  end

  # ONE APPLICATION, MORE THAN ONE CREDENTIAL SCHEME.
  #
  # A Rails app that mounts a second API routinely authenticates it differently, and
  # with a single strategy that mount is unauthenticated on every request -- which
  # surfaces as a block of endpoints failing identically, for a reason the report
  # attributes to the application. Observed for real: fourteen endpoints quarantined
  # across four rounds and diagnosed as a seeding problem, when no factory could ever
  # have helped.
  describe "per-mount credentials" do
    before do
      config.auth_token_provider = -> { %w[primary-a primary-b] }
      config.auth_overrides = [
        { paths: [%r{^/internal/partner/}], strategy: :bearer_token, token_provider: -> { %w[partner-a partner-b] } }
      ]
    end

    subject(:pool) { described_class.new(config: config, stdout: StringIO.new).resolve! }

    it "sends the override's credential on a matching path" do
      expect(pool.headers_for_next(path: "/internal/partner/calls")["Authorization"]).to eq("Bearer partner-a")
    end

    it "sends the run-level credential everywhere else" do
      expect(pool.headers_for_next(path: "/api/v1/widgets")["Authorization"]).to eq("Bearer primary-a")
    end

    # Independently: sharing one cursor would let traffic to one mount decide which
    # identity the other mount gets, which is the single-identity problem wearing a
    # different hat.
    it "rotates each mount's identities on its own cursor" do
      tokens = 3.times.map { pool.headers_for_next(path: "/internal/partner/calls")["Authorization"] }

      expect(tokens).to eq(["Bearer partner-a", "Bearer partner-b", "Bearer partner-a"])
      expect(pool.headers_for_next(path: "/api/v1/widgets")["Authorization"]).to eq("Bearer primary-a")
    end

    it "lets an override choose a different strategy and header name" do
      config.auth_overrides = [
        { paths: [%r{^/internal/}], strategy: :header, header_name: "Auth-Token",
          token_provider: -> { ["k1"] } }
      ]

      expect(pool.headers_for_next(path: "/internal/x")).to eq("Auth-Token" => "k1")
    end

    # A public primary API with a private second mount is an ordinary shape, and
    # returning early on "no run-level provider" would leave that mount
    # unauthenticated -- the exact failure this exists to fix.
    it "still applies overrides when the primary API needs no credential" do
      config.auth_token_provider = nil

      expect(pool.headers_for_next(path: "/internal/partner/calls")["Authorization"]).to eq("Bearer partner-a")
      expect(pool.headers_for_next(path: "/api/v1/widgets")).to eq({})
    end

    # Every request to those paths would be unauthenticated, and a report full of
    # 401s says nothing about the endpoints -- the same reasoning as the run-level
    # provider, which already refuses.
    it "refuses an override whose provider produces nothing" do
      config.auth_overrides = [{ paths: [%r{^/internal/}], token_provider: -> { [] } }]

      expect { pool }.to raise_error(Loadwright::SeedingError, /would be unauthenticated/)
    end

    it "falls back to the run-level credential when no path is supplied" do
      expect(pool.headers_for_next["Authorization"]).to eq("Bearer primary-a")
    end
  end

  describe "the :header strategy's header name" do
    it "is configurable, because X-Api-Key is one convention among many" do
      config.auth_strategy = :header
      config.auth_header_name = "Auth-Token"
      config.auth_token_provider = -> { ["k"] }
      pool = described_class.new(config: config, stdout: StringIO.new).resolve!

      expect(pool.headers_for_next).to eq("Auth-Token" => "k")
    end
  end
end

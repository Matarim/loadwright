# frozen_string_literal: true

# The most important spec file in the gem. Everything here is a variation on one
# question: does Loadwright refuse when it should?
#
# Working the testing-requirements list in references/production-safety.md.
RSpec.describe Loadwright::Safety::EnvironmentGuard do
  let(:config) { Loadwright::Configuration.new }

  # Resolved so the production path is reachable at all. Without a Rails app
  # this is nil, and an unresolvable phrase is its own refusal — tested
  # separately below rather than accidentally masking every other refusal.
  before { config.confirmation_phrase = "AcmeApp" }

  describe "Layer 1 — the environment allowlist" do
    it "approves a run in development" do
      guard = build_guard(config: config, env: { "RAILS_ENV" => "development" })

      decision = guard.approve!

      expect(decision.approved).to be(true)
      expect(decision.environment).to eq("development")
      expect(decision.environment_allowlisted).to be(true)
      expect(decision.production_adjacent).to be(false)
      expect(decision.conditions_cleared).to be_empty
    end

    it "approves a run in test" do
      guard = build_guard(config: config, env: { "RACK_ENV" => "test" })

      expect(guard.approve!.production_adjacent).to be(false)
    end

    # The core default-deny assertion, one example per excluded name. The
    # RefusingConfirmation double is what proves the refusal happened before any
    # prompt; the RaiseOnCall doubles below prove it happened before any work.
    %w[production staging prod production-eu live sandbox demo unknown].each do |environment|
      it "refuses to run in #{environment.inspect} with default config" do
        guard = build_guard(config: config, env: { "RAILS_ENV" => environment })

        expect { guard.approve! }
          .to raise_error(Loadwright::SafetyError, /production-adjacent/)
      end
    end

    # "This check happens first, before discovery, before touching the database,
    # before anything." Asserted with objects that fail loudly on any call, so an
    # accidental request in a future refactor breaks this spec rather than
    # silently working.
    it "aborts before any discovery, seeding, or request code path is reached" do
      discovery = SafetyHelpers::RaiseOnCall.new("discovery")
      seeder = SafetyHelpers::RaiseOnCall.new("seeder")
      transport = SafetyHelpers::RaiseOnCall.new("transport")
      guard = build_guard(config: config, env: { "RAILS_ENV" => "production" })

      run = lambda do
        guard.approve!
        # Unreachable if the guard behaves. Present so the spec fails with a
        # named collaborator rather than a missing expectation if it does not.
        discovery.endpoints
        seeder.seed!
        transport.issue(nil)
      end

      expect { run.call }.to raise_error(Loadwright::SafetyError)
    end

    # RAILS_ENV/RACK_ENV can be unset or wrong in some deploy setups, and the
    # safe reading of "no environment" is not "development".
    it "treats an unset environment as unknown, and therefore refuses" do
      guard = build_guard(config: config, env: {})

      expect { guard.approve! }.to raise_error(Loadwright::SafetyError, /"unknown"/)
    end

    it "honours a widened allowlist" do
      config.enabled_environments = %i[development test qa]
      guard = build_guard(config: config, env: { "RAILS_ENV" => "qa" })

      expect(guard.approve!.production_adjacent).to be(false)
    end
  end

  describe "Layer 2 — heuristic production detection" do
    # One example per shipped default pattern: it must fire on a matching value
    # and, below, not fire on a plausible dev/test one.
    {
      "an RDS hostname in DATABASE_URL" => {
        env: { "DATABASE_URL" => "postgres://user:pw@acme-prod.abc123.eu-west-1.rds.amazonaws.com/acme" },
        source: "DATABASE_URL host"
      },
      "a prod- prefixed hostname" => { hostname: "prod-web-04", source: "hostname" },
      "an .internal hostname" => { hostname: "web-04.acme.internal", source: "hostname" }
    }.each do |description, setup|
      it "fires on #{description}" do
        guard = build_guard(
          config: config,
          env: { "RAILS_ENV" => "development" }.merge(setup[:env] || {}),
          hostname: setup[:hostname] || "macbook.local",
          confirmation: SafetyHelpers::ScriptedConfirmation.new([])
        )

        decision = guard.approve!

        expect(decision.heuristic_matches.map(&:source)).to include(setup[:source])
      end
    end

    # A heuristic that false-positives on ordinary local values is a heuristic
    # people turn off, at which point it protects nobody.
    [
      { hostname: "macbook.local", env: {} },
      { hostname: "dev-laptop", env: {} },
      { hostname: "ci-runner-7", env: { "DATABASE_URL" => "postgres://localhost/acme_development" } },
      { hostname: "acme.test", env: { "DATABASE_URL" => "postgres://127.0.0.1:5432/acme_test" } }
    ].each do |setup|
      it "does not fire on hostname #{setup[:hostname].inspect} with #{setup[:env].inspect}" do
        guard = build_guard(
          config: config,
          env: { "RAILS_ENV" => "development" }.merge(setup[:env]),
          hostname: setup[:hostname]
        )

        expect(guard.approve!.heuristic_matches).to be_empty
      end
    end

    it "warns rather than blocks when a heuristic matches inside the allowlist" do
      stdout = StringIO.new
      guard = build_guard(
        config: config,
        env: { "RAILS_ENV" => "development" },
        hostname: "prod-web-04",
        stdout: stdout
      )

      expect(guard.approve!.approved).to be(true)
      expect(stdout.string).to match(/WARNING hostname "prod-web-04" matches/)
    end

    described_class::PLATFORM_SIGNALS.each_key do |variable|
      it "surfaces #{variable} as a warning, not a block" do
        stdout = StringIO.new
        guard = build_guard(
          config: config,
          env: { "RAILS_ENV" => "development", variable => "1" },
          stdout: stdout
        )

        decision = guard.approve!

        expect(decision.approved).to be(true)
        expect(decision.platform_signals.map(&:variable)).to eq([variable])
        expect(stdout.string).to include("WARNING #{variable} is set")
      end
    end

    it "extends rather than replaces the pattern list when a user adds their own" do
      config.production_hostname_patterns = [*config.production_hostname_patterns, /\Alive-/]
      guard = build_guard(
        config: config,
        env: { "RAILS_ENV" => "development" },
        hostname: "live-api-01"
      )

      expect(guard.approve!.heuristic_matches.map { |m| m.pattern.source }).to include("\\Alive-")
    end
  end

  describe "Layer 3 — the four conditions are each independently required" do
    # A production environment on a prod- hostname, so all four conditions are
    # in play at once. Dropping any one must still abort.
    def guard_with(confirmation:, allow_production: true, hostname: "prod-web-04")
      config.allow_production = allow_production
      build_guard(
        config: config,
        env: { "RAILS_ENV" => "production" },
        hostname: hostname,
        confirmation: confirmation
      )
    end

    it "approves when all four are satisfied" do
      confirmation = SafetyHelpers::ScriptedConfirmation.new(%i[correct correct])
      guard = guard_with(confirmation: confirmation)

      decision = guard.approve!(risk_acknowledged: true, execute: true)

      expect(decision.approved).to be(true)
      expect(decision.production_opt_in_used).to be(true)
      expect(decision.conditions_cleared)
        .to eq(%i[allow_production risk_flag typed_confirmation heuristic_confirmation])
    end

    it "aborts without allow_production, before prompting for anything" do
      guard = guard_with(confirmation: SafetyHelpers::RefusingConfirmation.new, allow_production: false)

      expect { guard.approve!(risk_acknowledged: true, execute: true) }
        .to raise_error(Loadwright::SafetyError, /allow_production is false/)
    end

    it "aborts without --i-understand-the-risk, before prompting for anything" do
      guard = guard_with(confirmation: SafetyHelpers::RefusingConfirmation.new)

      expect { guard.approve!(risk_acknowledged: false, execute: true) }
        .to raise_error(Loadwright::SafetyError, /--i-understand-the-risk was not passed/)
    end

    it "aborts when the typed confirmation phrase does not match" do
      confirmation = SafetyHelpers::ScriptedConfirmation.new(["not the app name"])
      guard = guard_with(confirmation: confirmation)

      expect { guard.approve!(risk_acknowledged: true, execute: true) }
        .to raise_error(Loadwright::SafetyError, /confirmation phrase did not match/)
    end

    it "aborts when the second, heuristics-specific confirmation is not given" do
      confirmation = SafetyHelpers::ScriptedConfirmation.new([:correct, "no thanks"])
      guard = guard_with(confirmation: confirmation)

      expect { guard.approve!(risk_acknowledged: true, execute: true) }
        .to raise_error(Loadwright::SafetyError)

      expect(confirmation.prompts.length).to eq(2)
      expect(confirmation.prompts.last).to include("PRODUCTION HEURISTICS MATCHED")
      expect(confirmation.prompts.last).to include("prod-web-04")
    end

    it "asks only once when no heuristic matched, since there is nothing extra to name" do
      confirmation = SafetyHelpers::ScriptedConfirmation.new([:correct])
      guard = guard_with(confirmation: confirmation, hostname: "macbook.local")

      decision = guard.approve!(risk_acknowledged: true, execute: true)

      expect(confirmation.prompts.length).to eq(1)
      expect(decision.conditions_cleared).not_to include(:heuristic_confirmation)
    end
  end

  describe "the confirmation phrase has no generic fallback" do
    # The app-module-name default exists precisely so the phrase cannot be
    # guessed generically. A hardcoded "I UNDERSTAND" would defeat that, so an
    # unresolvable phrase is a refusal.
    it "refuses the production-adjacent path rather than substituting a phrase" do
      config.allow_production = true
      config.confirmation_phrase = nil
      guard = build_guard(config: config, env: { "RAILS_ENV" => "production" })

      expect { guard.approve!(risk_acknowledged: true, execute: true) }
        .to raise_error(Loadwright::SafetyError) { |error|
              expect(error.message).to include("substitute a generic phrase")
              expect(error.message).to include("Set config.confirmation_phrase explicitly")
            }
    end

    it "is never consulted, and never raises, on an ordinary dev run" do
      guard = build_guard(config: config, env: { "RAILS_ENV" => "development" })

      expect { guard.approve! }.not_to raise_error
    end

    it "is nil rather than a fallback string when there is no Rails application" do
      expect(Loadwright::Configuration.new.confirmation_phrase).to be_nil
    end
  end

  describe "Layer 4 — dry run before real execution" do
    it "defaults a production-adjacent run to dry run" do
      config.allow_production = true
      confirmation = SafetyHelpers::ScriptedConfirmation.new([:correct])
      stdout = StringIO.new
      guard = build_guard(
        config: config,
        env: { "RAILS_ENV" => "production" },
        confirmation: confirmation,
        stdout: stdout
      )

      decision = guard.approve!(risk_acknowledged: true)

      expect(decision.dry_run).to be(true)
      expect(stdout.string).to include("DRY RUN")
      expect(stdout.string).to include("zero requests will be sent")
    end

    it "requires an explicit --execute to leave dry run" do
      config.allow_production = true
      confirmation = SafetyHelpers::ScriptedConfirmation.new([:correct])
      guard = build_guard(
        config: config,
        env: { "RAILS_ENV" => "production" },
        confirmation: confirmation
      )

      expect(guard.approve!(risk_acknowledged: true, execute: true).dry_run).to be(false)
    end
  end

  describe "Layer 1b — remote :http targets" do
    before { config.execution_mode = :http }

    it "treats a loopback target as an ordinary local run" do
      config.http_target_url = "http://127.0.0.1:3001"
      guard = build_guard(config: config, env: { "RAILS_ENV" => "development" })

      decision = guard.approve!

      expect(decision.production_adjacent).to be(false)
      expect(decision.remote_target).to be_nil
    end

    it "refuses a non-loopback target when allow_remote_http_target is false" do
      config.http_target_url = "http://staging.example.com"
      guard = build_guard(config: config, env: { "RAILS_ENV" => "development" })

      expect { guard.approve! }
        .to raise_error(Loadwright::SafetyError, /allow_remote_http_target is false/)
    end

    # Case 1: the full opt-in flow applies even though the LOCAL environment is
    # development, because the local Rails.env describes the wrong process.
    it "triggers the full opt-in flow even when the local environment is development" do
      config.http_target_url = "http://staging.example.com"
      config.allow_remote_http_target = true
      guard = build_guard(
        config: config,
        env: { "RAILS_ENV" => "development" },
        identifier: SafetyHelpers::ScriptedIdentifier.new(report: identity_report(environment: "development"))
      )

      expect { guard.approve!(risk_acknowledged: true, execute: true) }
        .to raise_error(Loadwright::SafetyError, /allow_production is false/)
    end

    # Case 2: a target self-reporting a disallowed environment is refused, with
    # no override path at all.
    it "hard-refuses a target reporting production, with no override" do
      config.http_target_url = "http://api.acme.com"
      config.allow_remote_http_target = true
      config.allow_production = true
      identifier = Loadwright::Safety::RemoteTargetIdentifier.new(
        config: config,
        fetcher: ->(*) { JSON.generate("env" => "production", "loadwright_version" => "0.0.1", "enabled_here" => false) }
      )
      guard = build_guard(
        config: config,
        env: { "RAILS_ENV" => "development" },
        identifier: identifier,
        confirmation: SafetyHelpers::ScriptedConfirmation.new(%i[correct correct])
      )

      expect { guard.approve!(risk_acknowledged: true, execute: true) }
        .to raise_error(Loadwright::SafetyError) { |error|
              expect(error.message).to include('"production"')
              expect(error.message).to include("no override for this")
            }
    end

    # Case 3: unreachable is refused, not assumed safe.
    it "refuses an unreachable target rather than assuming it is safe" do
      config.http_target_url = "http://staging.example.com"
      config.allow_remote_http_target = true
      identifier = Loadwright::Safety::RemoteTargetIdentifier.new(
        config: config,
        fetcher: ->(*) { raise Errno::ECONNREFUSED, "connect(2)" }
      )
      guard = build_guard(config: config, env: { "RAILS_ENV" => "development" }, identifier: identifier)

      expect { guard.approve! }
        .to raise_error(Loadwright::SafetyError) { |error|
              expect(error.message).to include("did not answer Loadwright's identity")
              expect(error.message).to include("treated as production")
            }
    end

    # Case 4: the asymmetry, in the direction people get wrong. A target saying
    # "development" grants nothing.
    it "grants nothing when the target reports an allowed environment" do
      config.http_target_url = "http://staging.example.com"
      config.allow_remote_http_target = true
      config.allow_production = true
      confirmation = SafetyHelpers::ScriptedConfirmation.new([:correct])
      guard = build_guard(
        config: config,
        env: { "RAILS_ENV" => "development" },
        identifier: SafetyHelpers::ScriptedIdentifier.new(report: identity_report(environment: "development")),
        confirmation: confirmation
      )

      decision = guard.approve!(risk_acknowledged: true, execute: true)

      expect(decision.production_adjacent).to be(true)
      expect(decision.conditions_cleared).to include(:allow_production, :risk_flag, :typed_confirmation)
      expect(confirmation.prompts.length).to eq(1)
    end

    # Case 5: hostname heuristics run against the TARGET's host, not only the
    # local one — otherwise a laptop named "macbook.local" launders a run at
    # prod-api.acme.internal.
    it "runs the hostname heuristics against the target's host" do
      config.http_target_url = "http://prod-api.acme.com"
      config.allow_remote_http_target = true
      config.allow_production = true
      guard = build_guard(
        config: config,
        env: { "RAILS_ENV" => "development" },
        hostname: "macbook.local",
        identifier: SafetyHelpers::ScriptedIdentifier.new(report: identity_report(environment: "development")),
        confirmation: SafetyHelpers::ScriptedConfirmation.new(%i[correct correct])
      )

      decision = guard.approve!(risk_acknowledged: true, execute: true)

      match = decision.heuristic_matches.find { |m| m.source == "http_target_url host" }
      expect(match.value).to eq("prod-api.acme.com")
      expect(decision.conditions_cleared).to include(:heuristic_confirmation)
    end

    # Case 6: provenance. A report must name what actually received traffic.
    it "records the resolved target host in the decision" do
      config.http_target_url = "http://staging.example.com"
      config.allow_remote_http_target = true
      config.allow_production = true
      guard = build_guard(
        config: config,
        env: { "RAILS_ENV" => "development" },
        identifier: SafetyHelpers::ScriptedIdentifier.new(report: identity_report(environment: "development")),
        confirmation: SafetyHelpers::ScriptedConfirmation.new([:correct])
      )

      decision = guard.approve!(risk_acknowledged: true, execute: true)

      expect(decision.remote_target.to_h).to include(
        host: "staging.example.com",
        environment: "development"
      )
      expect(decision.to_h[:remote_target][:host]).to eq("staging.example.com")
    end
  end

  describe "#production_adjacent?" do
    it "is false for an ordinary local dev run" do
      guard = build_guard(config: config, env: { "RAILS_ENV" => "development" })

      expect(guard.production_adjacent?).to be(false)
    end

    it "is true outside the allowlist" do
      guard = build_guard(config: config, env: { "RAILS_ENV" => "staging" })

      expect(guard.production_adjacent?).to be(true)
    end

    # The collection endpoint asks this before mounting. A question it cannot
    # answer must answer "yes".
    it "is true when the question cannot be answered" do
      config.http_target_url = "http://staging.example.com"
      config.allow_remote_http_target = true
      identifier = Loadwright::Safety::RemoteTargetIdentifier.new(
        config: config, fetcher: ->(*) { raise "network is down" }
      )
      guard = build_guard(config: config, env: { "RAILS_ENV" => "development" }, identifier: identifier)

      expect(guard.production_adjacent?).to be(true)
    end
  end

  describe "auditability" do
    # "A report should be able to answer 'was this run safe?' on its own,
    # without needing the terminal scrollback."
    it "returns every decision as data, not only as printed warnings" do
      guard = build_guard(
        config: config,
        env: { "RAILS_ENV" => "development", "DYNO" => "web.1" },
        hostname: "prod-web-04",
        confirmation: SafetyHelpers::ScriptedConfirmation.new([])
      )

      audit = guard.approve!.to_h

      expect(audit.keys).to include(
        :approved, :environment, :environment_allowlisted, :production_adjacent,
        :adjacency_reasons, :heuristic_matches, :platform_signals, :remote_target,
        :dry_run, :mutating_requests_allowed, :production_opt_in_used, :conditions_cleared
      )
      expect(audit[:heuristic_matches].first).to include(source: "hostname", value: "prod-web-04")
      expect(audit[:platform_signals]).to eq([{ variable: "DYNO", description: "Heroku dyno" }])
    end

    it "records whether mutating requests were permitted, since that is a separate gate" do
      guard = build_guard(config: config, env: { "RAILS_ENV" => "development" })

      expect(guard.approve!.mutating_requests_allowed).to be(false)
    end
  end
end

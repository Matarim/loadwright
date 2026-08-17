# frozen_string_literal: true

# Working the testing-requirements list in references/resource-contention.md.
RSpec.describe Loadwright::Engine::ResourceGuard do
  let(:config) { Loadwright::Configuration.new }

  before { stub_active_record_errors! }

  # ---------------------------------------------------------------- Tier 1 classes

  describe "Tier 1 classification" do
    subject(:guard) { build_guard_with(config: config).first }

    described_class::TIER_1_ERROR_NAMES.each do |name|
      it "classifies #{name} as contention at real concurrency" do
        error = Object.const_get(name).new("contention")

        expect(guard.classify(error, concurrency: 5)).to eq(:contention)
      end
    end

    # StatementInvalid wraps the interesting class, and the adapter may wrap that
    # again — so a naive `is_a?` check on the outermost exception misses every real
    # occurrence.
    it "sees through a wrapping StatementInvalid" do
      inner = ActiveRecord::LockWaitTimeout.new("lock wait timeout exceeded")
      outer = begin
        begin
          raise inner
        rescue StandardError
          raise ActiveRecord::StatementInvalid, "wrapped"
        end
      rescue StandardError => e
        e
      end

      expect(guard.classify(outer, concurrency: 5)).to eq(:contention)
    end

    it "leaves an ordinary error to the circuit breaker" do
      expect(guard.classify(ArgumentError.new("bad params"), concurrency: 5)).to eq(:other)
      expect(guard.classify(nil, concurrency: 5)).to eq(:other)
    end
  end

  # The structural half of the breaker/guard split. A run generating contention
  # errors well above max_error_rate_before_abort must not trip the breaker, because
  # the guard is handling them correctly.
  describe "contention is excluded from the circuit breaker" do
    it "does not trip the breaker at any volume of Tier 1 errors" do
      guard = build_guard_with(config: config).first
      breaker = Loadwright::Engine::CircuitBreaker.new(config: config)

      100.times do
        error = ActiveRecord::LockWaitTimeout.new("lock wait timeout")
        case guard.classify(error, concurrency: 5)
        when :contention then breaker.record_contention
        else breaker.record_error
        end
      end

      expect(breaker).not_to be_tripped
      expect(breaker.contention_events).to eq(100)
      expect(breaker.errors).to eq(0)
    end
  end

  # -------------------------------------------------------------- the two carve-outs

  describe "carve-out: pool exhaustion at concurrency 1" do
    # ConnectionTimeoutError under real concurrency is load pressure. The same error
    # with one request in flight means nothing else was competing for a connection —
    # a different diagnosis entirely, and the concurrency level is what distinguishes
    # them.
    it "is an endpoint finding, not a contention event" do
      guard = build_guard_with(config: config).first
      error = ActiveRecord::ConnectionTimeoutError.new("could not obtain a connection")

      expect(guard.classify(error, concurrency: 1)).to eq(:endpoint_finding)

      guard.observe(endpoint_key: "GET /api/v1/posts", concurrency: 1, error: error)

      finding = guard.findings.first
      expect(finding.kind).to eq(:suspected_connection_leak)
      expect(finding.detail).to include("checks out a connection it never returns")
      expect(finding.detail).to include("thread spawned mid-request")
    end

    it "routes the same error to the guard at higher concurrency" do
      guard = build_guard_with(config: config).first
      error = ActiveRecord::ConnectionTimeoutError.new("could not obtain a connection")

      expect(guard.classify(error, concurrency: 20)).to eq(:contention)
    end

    it "reports the leak once, not once per request" do
      guard = build_guard_with(config: config).first
      error = ActiveRecord::ConnectionTimeoutError.new("timeout")

      5.times { guard.observe(endpoint_key: "GET /x", concurrency: 1, error: error) }

      expect(guard.findings.length).to eq(1)
    end
  end

  describe "carve-out: repeat offender" do
    # Routing all contention to the guard must not let a genuine endpoint defect
    # disappear into "the database was under pressure".
    it "becomes an endpoint finding when the blocker was ours across several cells" do
      guard, = build_guard_with(config: config, contended: true, blocker: :ours)

      2.times do
        guard.escalate(endpoint_key: "PATCH /api/v1/posts/{id}", concurrency: 5, kind: :tier_1)
      end

      finding = guard.findings.find { |f| f.kind == :repeat_offender }
      expect(finding).not_to be_nil
      expect(finding.detail).to include("blocking session was Loadwright's own")
      expect(finding.evidence.length).to be >= 2
    end

    it "does not fire when the blocker was somebody else's" do
      guard, = build_guard_with(config: config, contended: true, blocker: :external)

      3.times { guard.escalate(endpoint_key: "GET /x", concurrency: 5, kind: :tier_1) }

      expect(guard.findings.map(&:kind)).not_to include(:repeat_offender)
    end

    # Blaming an endpoint for a lock we cannot PROVE was ours is a false positive,
    # and a false positive here destroys trust in every other finding.
    it "does not fire when the blocker could not be identified" do
      guard, = build_guard_with(config: config, contended: true, blocker: :unknown)

      3.times { guard.escalate(endpoint_key: "GET /x", concurrency: 5, kind: :tier_1) }

      expect(guard.findings.map(&:kind)).not_to include(:repeat_offender)
      expect(guard.events.map(&:blocker).uniq).to eq(["unknown"])
    end

    it "fires only once for the same endpoint" do
      guard, = build_guard_with(config: config, contended: true, blocker: :ours)

      5.times { guard.escalate(endpoint_key: "GET /x", concurrency: 5, kind: :tier_1) }

      expect(guard.findings.count { |f| f.kind == :repeat_offender }).to eq(1)
    end
  end

  # -------------------------------------------------------------------- the ladder

  describe "the response ladder escalates in order" do
    # pause -> step down -> quarantine -> cooldown -> next endpoint, rather than
    # jumping straight to abort.
    # The requirement is about ORDER: escalate through the rungs rather than jumping
    # straight to abort. The terminal rung on a permanently-contended database is
    # legitimately an abort — a database that never recovers during cooldown is not
    # recovering at all — so the two ways of reaching Rung 5 are asserted in their own
    # examples below, and this one asserts the path taken to get there.
    it "walks the rungs in order rather than jumping to abort" do
      config.max_backoff_attempts = 2
      config.concurrency_levels = [1, 5, 20]
      config.max_consecutive_quarantines = 99
      guard, = build_guard_with(config: config, contended: true, blocker: :ours)

      # The concurrency is threaded through as the engine does it. A caller that
      # ignored a step-down would loop on the same rung forever, which is a contract
      # worth stating here rather than discovering in the engine.
      concurrency = 20
      rungs = []
      5.times do
        decision = guard.escalate(endpoint_key: "GET /x", concurrency: concurrency, kind: :tier_1)
        rungs << decision.rung
        concurrency = decision.concurrency if decision.concurrency
      end

      expect(rungs).to eq(%i[pause pause step_down step_down abort])
      # Nothing was abandoned or aborted before the pauses and the step-downs had
      # their turn, which is the whole point of a ladder.
      expect(rungs.first(4)).not_to include(:abort, :quarantine)
    end

    it "resumes at the same concurrency when a pause recovers" do
      config.max_backoff_attempts = 4
      # Contended when the escalation starts, healthy on the poll after the pause.
      guard, = build_guard_with(config: config, contended: true, blocker: :ours, recovers_after: 0)

      decision = guard.escalate(endpoint_key: "GET /x", concurrency: 20, kind: :tier_1)

      expect(decision.rung).to eq(:proceed)
      expect(decision.reason).to eq("recovered after backoff")
    end

    it "steps down to the next lower configured level, not to 1" do
      config.max_backoff_attempts = 0
      config.concurrency_levels = [1, 5, 20]
      guard, = build_guard_with(config: config, contended: true, blocker: :ours)

      expect(guard.escalate(endpoint_key: "GET /x", concurrency: 20, kind: :tier_1).concurrency).to eq(5)
    end

    it "quarantines rather than stepping down when already at the lowest level" do
      config.max_backoff_attempts = 0
      config.concurrency_levels = [1, 5]
      config.max_consecutive_quarantines = 99
      guard, = build_guard_with(config: config, contended: true, blocker: :ours, recovers_after: 1)

      decision = guard.escalate(endpoint_key: "GET /x", concurrency: 1, kind: :tier_1)

      expect(decision.rung).to eq(:quarantine)
      expect(decision.reason).to include("the run continues")
      expect(guard).to be_quarantined("GET /x")
    end

    # Rung 5. At that point the database is not recovering and continuing does harm
    # rather than gathering data.
    it "aborts globally after max_consecutive_quarantines" do
      config.max_backoff_attempts = 0
      config.concurrency_levels = [1]
      config.max_consecutive_quarantines = 2
      # Recovers after each cooldown, so the abort is attributable to the quarantine
      # COUNT rather than to a health check that never passed.
      guard, = build_guard_with(config: config, contended: true, blocker: :ours, recovers_after: 1)

      first = guard.escalate(endpoint_key: "GET /a", concurrency: 1, kind: :tier_1)
      second = guard.escalate(endpoint_key: "GET /b", concurrency: 1, kind: :tier_1)

      expect(first.rung).to eq(:quarantine)
      expect(second.rung).to eq(:abort)
      expect(second.reason).to include("max_consecutive_quarantines")
    end

    # Rung 5's other trigger. The quarantine COUNT is not the only way to reach an
    # abort: a database that never recovers during cooldown is not recovering at all,
    # and continuing would be doing harm rather than gathering data.
    it "aborts when the post-quarantine health check never passes" do
      config.max_backoff_attempts = 0
      config.concurrency_levels = [1]
      config.max_consecutive_quarantines = 99
      guard, = build_guard_with(config: config, contended: true, blocker: :ours)

      decision = guard.escalate(endpoint_key: "GET /x", concurrency: 1, kind: :tier_1)

      expect(decision.rung).to eq(:abort)
      expect(decision.reason).to include("post-quarantine health check failed")
    end

    it "waits post_quarantine_cooldown_ms before the next endpoint" do
      config.max_backoff_attempts = 0
      config.concurrency_levels = [1]
      config.max_consecutive_quarantines = 99
      config.post_quarantine_cooldown_ms = 5_000
      guard, _poller, slept = build_guard_with(config: config, contended: true, blocker: :ours,
                                               recovers_after: 1)

      guard.escalate(endpoint_key: "GET /x", concurrency: 1, kind: :tier_1)

      expect(slept).to include(5.0)
    end

    it "resets the ladder for an endpoint that recovers, so old attempts do not carry over" do
      config.max_backoff_attempts = 1
      guard, = build_guard_with(config: config, contended: true, blocker: :ours)

      guard.escalate(endpoint_key: "GET /x", concurrency: 20, kind: :tier_1)
      guard.note_recovery("GET /x")

      expect(guard.escalate(endpoint_key: "GET /x", concurrency: 20, kind: :tier_1).rung).to eq(:pause)
    end
  end

  describe "an unresponsive app process" do
    # A failure mode :in_process cannot produce. Continuing to issue requests into a
    # dead process is pointless, so it is Rung 5 immediately.
    it "aborts the run rather than stepping down" do
      guard, = build_guard_with(config: config, contended: false, target_alive: false)

      decision = guard.check_cell!(endpoint_key: "GET /x", concurrency: 5)

      expect(decision.rung).to eq(:abort)
      expect(decision.reason).to include("stopped responding")
    end
  end

  # -------------------------------------------------------------------- Tier 3

  describe "Tier 3 latency degradation" do
    # Catches contention that manifests as queueing rather than as errors: no
    # exception raised, no lock visible.
    it "escalates after the configured number of sustained windows" do
      config.latency_degradation_multiplier = 4.0
      config.degradation_windows_before_backoff = 3
      guard, = build_guard_with(config: config, contended: true, blocker: :ours)
      guard.record_baseline_latency("GET /x", [10, 10, 12, 11])

      rungs = 3.times.map do
        guard.observe(endpoint_key: "GET /x", concurrency: 5, latency_ms: 500).rung
      end

      expect(rungs.first(2)).to eq(%i[proceed proceed])
      expect(rungs.last).not_to eq(:proceed)
    end

    it "resets the window count when latency recovers" do
      config.degradation_windows_before_backoff = 3
      guard, = build_guard_with(config: config, contended: true, blocker: :ours)
      guard.record_baseline_latency("GET /x", [10])

      guard.observe(endpoint_key: "GET /x", concurrency: 5, latency_ms: 500)
      guard.observe(endpoint_key: "GET /x", concurrency: 5, latency_ms: 500)
      guard.observe(endpoint_key: "GET /x", concurrency: 5, latency_ms: 11)
      decision = guard.observe(endpoint_key: "GET /x", concurrency: 5, latency_ms: 500)

      expect(decision.rung).to eq(:proceed)
    end

    # The baseline is measured at concurrency 1 before ramping, and without it there
    # is nothing to compare against — so Tier 3 must stay silent rather than compare
    # against an arbitrary constant.
    it "does nothing without a baseline for that endpoint" do
      guard, = build_guard_with(config: config, contended: true)

      10.times do
        expect(guard.observe(endpoint_key: "GET /unmeasured", concurrency: 5, latency_ms: 9_999).rung)
          .to eq(:proceed)
      end
    end

    it "uses the endpoint's own p95, not its mean" do
      guard, = build_guard_with(config: config)
      guard.record_baseline_latency("GET /x", [10, 10, 10, 10, 10, 10, 10, 10, 10, 100])

      expect(guard.baseline_for("GET /x")).to eq(100)
    end
  end

  # ------------------------------------------------------------------- pre-flight

  describe "the baseline health check" do
    # Running a load test into an already-sick database produces garbage data and
    # risks tipping over something a developer cares about.
    it "refuses to start when the database is already contended" do
      guard, = build_guard_with(config: config, contended: true, blocker: :external)

      expect { guard.check_baseline! }.to raise_error(Loadwright::RunAborted) { |error|
        expect(error.rung).to eq(:baseline)
        expect(error.message).to include("already contended before Loadwright has done anything")
        expect(error.message).to include("migration in flight")
      }
    end

    it "proceeds with a warning when the user accepts an unhealthy baseline" do
      config.abort_on_unhealthy_baseline = false
      stdout = StringIO.new
      guard, = build_guard_with(config: config, contended: true, stdout: stdout)

      expect { guard.check_baseline! }.not_to raise_error
      expect(stdout.string).to include("WARNING the database was already contended")
    end

    it "records the baseline sample for the report" do
      guard, = build_guard_with(config: config, contended: false)

      guard.check_baseline!

      expect(guard.baseline.to_h).to include(contended: false)
    end

    it "registers our own sessions, so ours-vs-external has something to compare" do
      guard, poller = build_guard_with(config: config, contended: false)

      guard.preflight!

      expect(poller.registered).to be(true)
    end
  end

  # --------------------------------------------------------------- backoff budget

  describe "#backoff_budget" do
    # CLAUDE.md corollary 7: nobody should discover a four-hour run by waiting
    # through it, and DIAG-09 exists because a backing-off run looks hung.
    it "computes the documented default series" do
      budget = guard_for_defaults.backoff_budget

      expect(budget[:delays_ms]).to eq([250, 500, 1000, 2000])
      expect(budget[:per_contention_event_ms]).to eq(3_750)
      expect(budget[:worst_case_before_abort_ms]).to eq(3 * (3_750 + 5_000))
    end

    it "respects the delay cap" do
      config.backoff_initial_delay_ms = 10_000
      config.backoff_max_delay_ms = 15_000
      config.max_backoff_attempts = 4

      expect(build_guard_with(config: config).first.backoff_budget[:delays_ms])
        .to eq([10_000, 15_000, 15_000, 15_000])
    end

    it "includes jitter in the worst case, since jitter is additive per delay" do
      budget = guard_for_defaults.backoff_budget

      expect(budget[:worst_case_with_jitter_ms])
        .to eq((budget[:worst_case_before_abort_ms] * 1.3).round)
    end

    it "renders a line fit to print at run start" do
      expect(guard_for_defaults.describe_budget)
        .to match(/backoff budget — 3\.75s per event .*worst case 34\.1s before a global abort/)
    end

    def guard_for_defaults = build_guard_with(config: config).first
  end

  # ------------------------------------------------------------- the absolute rule

  describe "never resolving contention" do
    # Asserted on the SQL actually executed, and on the source, so a future
    # well-meaning "let's just clear the blocker" change fails loudly.
    it "issues no terminate, cancel, kill, or unlock statement under any scenario", :sample_app do
      # The baseline gate is not what is under test here, and a contended baseline
      # would abort before any of the ladder ran.
      config.abort_on_unhealthy_baseline = false
      guard = described_class.new(
        config: config,
        poller: ContentionHelpers::ScriptedPoller.new(contended: true, blocker: :ours),
        stdout: StringIO.new,
        sleeper: ->(_) { nil }
      )

      guard.preflight!
      5.times { guard.escalate(endpoint_key: "GET /x", concurrency: 1, kind: :tier_1) }
      guard.observe(endpoint_key: "GET /x", concurrency: 1,
                    error: ActiveRecord::ConnectionTimeoutError.new("timeout"))

      expect(guard.executed_statements.join("\n"))
        .not_to match(Loadwright::Engine::HealthPoller::FORBIDDEN_STATEMENTS)
    end

    it "contains no such statement in its source at all" do
      %w[resource_guard.rb health_poller.rb].each do |file|
        source = File.read(File.join(SpecPaths::LIB, "engine", file))
        code = source.lines.reject { |line| line.strip.start_with?("#") }
                     .reject { |line| line.include?("FORBIDDEN_STATEMENTS") }
                     .join

        expect(code).not_to match(/pg_terminate_backend|pg_cancel_backend|UNLOCK\s+TABLES/i),
                            "#{file} contains a statement that resolves contention rather than retreating"
      end
    end
  end

  # ------------------------------------------------------------------- seeding

  describe "contention during seeding" do
    it "asks the seeder to pause, then to stop if it does not recover" do
      guard, _poller, slept = build_guard_with(config: config, contended: true, blocker: :ours)

      expect(guard.check_seeding_batch!(resource: "post", created: 50, target: 200)).to eq(:stop)
      expect(slept).not_to be_empty
    end

    it "lets seeding continue once health recovers" do
      guard, = build_guard_with(config: config, contended: true, recovers_after: 0)

      expect(guard.check_seeding_batch!(resource: "post", created: 50, target: 200)).to eq(:continue)
    end

    it "does not interfere on a healthy database" do
      guard, = build_guard_with(config: config, contended: false)

      expect(guard.check_seeding_batch!(resource: "post", created: 0, target: 200)).to eq(:continue)
    end
  end

  # ---------------------------------------------------------------- session timeouts

  describe "pre-flight session timeouts", :sample_app do
    # SQLite has no session lock/statement timeouts, and that is a reduction in
    # protection to report rather than hide.
    it "says so plainly on an adapter that has none" do
      guard, = build_guard_with(config: config, contended: false)

      result = guard.preflight!

      expect(result.timeouts[:applied]).to be(false)
      expect(result.timeouts[:reason]).to include("no session lock/statement timeouts")
    end
  end

  describe "#to_h" do
    it "reports every event, finding and quarantine for the report metadata" do
      config.max_backoff_attempts = 0
      config.concurrency_levels = [1]
      config.max_consecutive_quarantines = 99
      guard, = build_guard_with(config: config, contended: true, blocker: :ours)
      guard.escalate(endpoint_key: "GET /x", concurrency: 1, kind: :tier_1)

      audit = guard.to_h

      expect(audit[:events].first).to include(endpoint: "GET /x", kind: :tier_1, blocker: "ours")
      expect(audit[:quarantined]).to eq(["GET /x"])
      expect(audit[:backoff_budget]).to include(:worst_case_with_jitter_ms)
    end
  end
end

# frozen_string_literal: true

require "loadwright/errors"
require "loadwright/engine/health_poller"

module Loadwright
  module Engine
    # Detects database contention and RETREATS from it.
    #
    # GOVERNING PRINCIPLE, from resource-contention.md, with no exceptions:
    # Loadwright observes contention and retreats. It NEVER tries to resolve it. No
    # pg_terminate_backend, no pg_cancel_backend, no KILL, no UNLOCK TABLES. If the
    # database is struggling, the correct action is always to send it LESS work,
    # never to intervene in what it is already doing. A spec asserts on the SQL
    # actually executed so a future well-meaning change cannot introduce one.
    #
    # THIS EXISTS BEFORE THE LOAD ENGINE, deliberately (CLAUDE.md build order): the
    # engine is the thing that generates concurrent load, and it must not exist in a
    # form that can generate load without a working guard around it.
    #
    # ---------------------------------------------------------------------------
    # THE BREAKER/GUARD SPLIT, which is structural rather than something an operator
    # tunes:
    #
    #   CircuitBreaker -> "this endpoint is broken"        (auth, routing, 500s)
    #   ResourceGuard  -> "the database is under pressure" (locks, pool, timeouts)
    #
    # Contention naturally PRODUCES errors. Counting them toward the breaker's error
    # rate makes the two mechanisms fight — the breaker aborts runs the guard was
    # handling correctly. So Tier 1 exception classes are classified here and
    # excluded from the breaker's numerator.
    #
    # TWO CARVE-OUTS, because routing all contention to the guard must not let a
    # genuine endpoint defect disappear into "the database was under pressure":
    #
    #   1. REPEAT OFFENDER. Blocker was ours AND the same endpoint triggers
    #      contention across multiple cells -> the endpoint takes locks it should
    #      not, or holds them too long. An endpoint finding, not only telemetry.
    #
    #   2. POOL EXHAUSTION AT CONCURRENCY 1. ConnectionTimeoutError under real
    #      concurrency is load pressure and belongs to the guard. The SAME error with
    #      one request in flight is almost certainly an application connection LEAK —
    #      the endpoint checked out a connection it never returned. Completely
    #      different diagnosis, and the concurrency level is what distinguishes them.
    # ---------------------------------------------------------------------------
    class ResourceGuard
      # Tier 1 — definitive contention signals on the request path. Resolved by NAME
      # rather than by constant, so the guard loads and behaves sanely in a process
      # with no ActiveRecord (the Null-transport tests, and a host app that somehow
      # has none).
      TIER_1_ERROR_NAMES = %w[
        ActiveRecord::LockWaitTimeout
        ActiveRecord::Deadlocked
        ActiveRecord::StatementTimeout
        ActiveRecord::QueryCanceled
        ActiveRecord::ConnectionTimeoutError
      ].freeze

      POOL_EXHAUSTION = "ActiveRecord::ConnectionTimeoutError"

      # What the guard tells the engine to do. The ladder in order.
      RUNGS = %i[proceed pause step_down quarantine cooldown abort].freeze

      # One contention observation.
      Event = Struct.new(:endpoint_key, :concurrency, :kind, :error_class, :blocker, :rung, :at,
                         keyword_init: true) do
        def to_h
          { endpoint: endpoint_key, concurrency: concurrency, kind: kind, error_class: error_class,
            blocker: blocker, rung: rung, at: at }
        end
      end

      # A contention observation that is ALSO an endpoint finding — the two carve-outs.
      Finding = Struct.new(:endpoint_key, :kind, :detail, :evidence, keyword_init: true) do
        def to_h = { endpoint: endpoint_key, kind: kind, detail: detail, evidence: evidence }
      end

      Decision = Struct.new(:rung, :reason, :concurrency, :delay_ms, :blocker, keyword_init: true) do
        def proceed? = rung == :proceed
        def quarantine? = rung == :quarantine
        def abort? = rung == :abort

        def to_h = { rung: rung, reason: reason, concurrency: concurrency, delay_ms: delay_ms, blocker: blocker }
      end

      attr_reader :events, :findings, :baseline, :quarantined, :poller

      def initialize(config: Loadwright.configuration, poller: nil, server: nil,
                     stdout: $stdout, sleeper: nil, run_id: nil)
        @config = config
        @poller = poller || HealthPoller.new(config: config, server: server, run_id: run_id)
        @stdout = stdout
        @sleeper = sleeper || ->(seconds) { sleep(seconds) }
        @events = []
        @findings = []
        @quarantined = []
        @baselines = {}
        @degradation_windows = {}
        @backoff_attempts = {}
        @consecutive_quarantines = 0
        @health_check_failures = 0
        @executed_statements = []
        @mutex = Mutex.new
      end

      # ------------------------------------------------------- Part 0: pre-flight

      # Conservative session timeouts so a blocked query surfaces as a catchable
      # error in seconds instead of hanging the run. A run where every request hangs
      # for 30s because the default lock timeout is effectively infinite is both
      # useless and dangerous.
      def preflight!
        applied = apply_session_timeouts
        @poller.register_our_sessions!

        baseline = check_baseline!

        Struct.new(:timeouts, :baseline, keyword_init: true).new(timeouts: applied, baseline: baseline)
      end

      # Part 1 — baseline health check. Two purposes: establish what "normal" means
      # for THIS database, and detect contention that was already there. Running a
      # load test into an already-sick database produces garbage data and risks
      # tipping over something a developer cares about.
      def check_baseline!
        sample = @poller.sample
        @baseline = sample

        return sample unless sample&.contended?

        unless @config.abort_on_unhealthy_baseline
          @stdout.puts "loadwright: WARNING the database was already contended before this run started " \
                       "(#{describe(sample)}). Results will be hard to attribute; " \
                       "abort_on_unhealthy_baseline is false so continuing anyway."
          return sample
        end

        raise RunAborted.new(<<~MSG.strip, rung: :baseline)
          refusing to start: the database is already contended before Loadwright has done anything.

            #{describe(sample)}

          The usual causes are a migration in flight, a long-running transaction someone left open, or
          another load test. Running into this produces garbage data and risks tipping over something
          that matters. Set config.abort_on_unhealthy_baseline = false to proceed anyway.
        MSG
      end

      # ------------------------------------------------------ Tier 1 classification

      # :contention        -> route to this guard, EXCLUDE from the breaker
      # :endpoint_finding  -> an endpoint defect that happens to look like contention
      # :other             -> not contention; the breaker's business
      def classify(error, concurrency:)
        return :other if error.nil?

        name = tier_1_name(error)
        return :other if name.nil?

        # Carve-out 2. Pool exhaustion with a single request in flight is not load
        # pressure — nothing else was competing for a connection.
        return :endpoint_finding if name == POOL_EXHAUSTION && concurrency.to_i <= 1

        :contention
      end

      # Walks the cause chain, because StatementInvalid wraps the interesting class
      # and the adapter may wrap that again.
      def tier_1_name(error)
        current = error
        seen = 0

        while current && seen < 5
          klass = current.class.name
          return klass if TIER_1_ERROR_NAMES.include?(klass)

          ancestor = current.class.ancestors.map(&:name).find { |n| TIER_1_ERROR_NAMES.include?(n) }
          return ancestor if ancestor

          current = current.respond_to?(:cause) ? current.cause : nil
          seen += 1
        end

        nil
      end

      # ------------------------------------------------------------ Tier 3 baseline

      # Measured at concurrency 1 BEFORE ramping. A hard dependency, not an
      # optimisation: Tier 3 compares against this endpoint's own baseline rather
      # than an arbitrary constant, and there is nothing to compare against otherwise.
      def record_baseline_latency(endpoint_key, latencies)
        samples = Array(latencies).compact
        return nil if samples.empty?

        @mutex.synchronize { @baselines[endpoint_key] = percentile(samples, 0.95) }
      end

      def baseline_for(endpoint_key) = @mutex.synchronize { @baselines[endpoint_key] }

      # ------------------------------------------------------------- the observation

      # Called per request. Returns a Decision — the engine acts on the rung.
      def observe(endpoint_key:, concurrency:, latency_ms: nil, error: nil)
        classification = classify(error, concurrency: concurrency)

        if classification == :endpoint_finding
          record_connection_leak(endpoint_key, error, concurrency)
          return Decision.new(rung: :proceed, reason: "suspected connection leak, reported as a finding")
        end

        if classification == :contention
          return escalate(endpoint_key: endpoint_key, concurrency: concurrency,
                          kind: :tier_1, error_class: error.class.name)
        end

        # Tier 3 — degradation with no exception raised and no lock visible. Catches
        # contention that manifests as queueing rather than as errors.
        if degradation_sustained?(endpoint_key, latency_ms)
          return escalate(endpoint_key: endpoint_key, concurrency: concurrency, kind: :tier_3)
        end

        Decision.new(rung: :proceed, reason: nil)
      end

      # Called between cells. Tier 2 lives here rather than per-request so the
      # background poll is read once per cell rather than contended over.
      def check_cell!(endpoint_key:, concurrency:)
        sample = @poller.latest || @poller.sample

        # :http only — the app process dying is a failure mode :in_process cannot
        # produce, and it is a Rung 5 abort rather than something to keep issuing
        # requests into.
        if sample&.target_alive == false
          return escalate(endpoint_key: endpoint_key, concurrency: concurrency, kind: :target_dead,
                          force: :abort)
        end

        return Decision.new(rung: :proceed, reason: nil) unless sample&.contended?

        escalate(endpoint_key: endpoint_key, concurrency: concurrency, kind: :tier_2, sample: sample)
      end

      # Contention during seeding: back off and retry the batch; if it still fails,
      # skip that resource rather than aborting the whole run.
      def check_seeding_batch!(resource:, created:, target:)
        sample = @poller.latest || @poller.sample
        return :continue unless sample&.contended?

        @stdout.puts "loadwright: pausing seeding of #{resource} at #{created}/#{target} — #{describe(sample)}"
        @sleeper.call(@config.backoff_initial_delay_ms / 1000.0)

        @poller.sample&.contended? ? :stop : :continue
      end

      # ----------------------------------------------------------------- the ladder

      def escalate(endpoint_key:, concurrency:, kind:, error_class: nil, sample: nil, force: nil)
        sample ||= @poller.latest
        blocker = blocker_attribution(sample)

        rung = force || next_rung(endpoint_key, concurrency)
        decision = act(rung, endpoint_key: endpoint_key, concurrency: concurrency, blocker: blocker, kind: kind)

        @mutex.synchronize do
          @events << Event.new(
            endpoint_key: endpoint_key, concurrency: concurrency, kind: kind,
            error_class: error_class, blocker: blocker, rung: decision.rung, at: Time.now
          )
        end

        maybe_record_repeat_offender(endpoint_key, blocker)
        decision
      end

      def to_h
        {
          baseline: @baseline&.to_h,
          poller: @poller.to_h,
          events: @events.map(&:to_h),
          event_count: @events.length,
          findings: @findings.map(&:to_h),
          quarantined: @quarantined,
          consecutive_quarantines: @consecutive_quarantines,
          backoff_budget: backoff_budget,
          endpoint_baselines_ms: @baselines
        }
      end

      # CLAUDE.md corollary 7 and resource-contention.md both require this be PRINTED
      # AT RUN START. It is easy to configure a run that appears hung when it is
      # actually just being patient, and DIAG-09 exists because people do.
      def backoff_budget
        delays = backoff_series
        per_event = delays.sum
        cooldown = @config.post_quarantine_cooldown_ms
        worst = @config.max_consecutive_quarantines * (per_event + cooldown)

        {
          delays_ms: delays,
          per_contention_event_ms: per_event,
          post_quarantine_cooldown_ms: cooldown,
          worst_case_before_abort_ms: worst,
          jitter: @config.backoff_jitter,
          # Jitter is additive on each delay, so the worst case is the nominal figure
          # plus jitter on every delay in the series.
          worst_case_with_jitter_ms: (worst * (1 + @config.backoff_jitter)).round
        }
      end

      def describe_budget
        budget = backoff_budget
        format(
          "loadwright: contention backoff budget — %<per>.2fs per event " \
          "(%<series>s), %<cooldown>.2fs cooldown per quarantine, " \
          "worst case %<worst>.1fs before a global abort (+ up to %<jitter>d%% jitter)",
          per: budget[:per_contention_event_ms] / 1000.0,
          series: budget[:delays_ms].map { |ms| "#{ms}ms" }.join(" + "),
          cooldown: budget[:post_quarantine_cooldown_ms] / 1000.0,
          worst: budget[:worst_case_with_jitter_ms] / 1000.0,
          jitter: (budget[:jitter] * 100).round
        )
      end

      def quarantined?(endpoint_key) = @quarantined.include?(endpoint_key)

      def stop! = @poller.stop!

      # Every statement this guard executed, for the spec that proves no
      # terminate/cancel/kill is ever issued.
      def executed_statements = @mutex.synchronize { @executed_statements.dup }

      private

      def next_rung(endpoint_key, concurrency)
        attempts = @mutex.synchronize { @backoff_attempts[endpoint_key] = @backoff_attempts.fetch(endpoint_key, 0) + 1 }

        # Rung 1 — pause and drain, up to max_backoff_attempts.
        return :pause if attempts <= @config.max_backoff_attempts

        # Rung 2 — step down concurrency, unless we are already at the floor.
        return :step_down if concurrency.to_i > lowest_concurrency

        # Rung 3 — abandon the endpoint.
        :quarantine
      end

      def act(rung, endpoint_key:, concurrency:, blocker:, kind:)
        case rung
        when :pause
          delay = jittered(backoff_series[[@backoff_attempts[endpoint_key] - 1, backoff_series.length - 1].min])
          @stdout.puts "loadwright: contention on #{endpoint_key} (#{kind}, blocker: #{blocker}); " \
                       "pausing #{delay.round}ms and re-polling"
          @sleeper.call(delay / 1000.0)

          recovered = !(@poller.sample&.contended?)
          Decision.new(rung: recovered ? :proceed : :pause, delay_ms: delay.round, blocker: blocker,
                       reason: recovered ? "recovered after backoff" : "still contended after backoff")

        when :step_down
          lower = step_down_from(concurrency)
          @stdout.puts "loadwright: stepping #{endpoint_key} down from concurrency #{concurrency} to #{lower}"
          Decision.new(rung: :step_down, concurrency: lower, blocker: blocker,
                       reason: "contention persisted at concurrency #{concurrency}")

        when :quarantine
          quarantine!(endpoint_key, blocker, kind)

        when :abort
          Decision.new(rung: :abort, blocker: blocker,
                       reason: "the app under test stopped responding; continuing would issue requests " \
                               "into a dead process")
        else
          Decision.new(rung: :proceed, reason: nil)
        end
      end

      def quarantine!(endpoint_key, blocker, kind)
        @mutex.synchronize do
          @quarantined << endpoint_key unless @quarantined.include?(endpoint_key)
          @consecutive_quarantines += 1
        end

        @stdout.puts "loadwright: quarantining #{endpoint_key} — contention persisted at the lowest " \
                     "concurrency level (#{kind}, blocker: #{blocker})"

        # Rung 4 — cooldown, then re-check. Starting the next endpoint into a
        # database that has not recovered cascades into false quarantines and keeps
        # the pressure on.
        @sleeper.call(@config.post_quarantine_cooldown_ms / 1000.0)
        recovered = cooldown_recovered?

        # Rung 5 — global abort.
        if @consecutive_quarantines >= @config.max_consecutive_quarantines
          return Decision.new(rung: :abort, blocker: blocker,
                              reason: "#{@consecutive_quarantines} consecutive quarantines " \
                                      "(max_consecutive_quarantines); the database is not recovering")
        end

        unless recovered
          return Decision.new(rung: :abort, blocker: blocker,
                              reason: "the post-quarantine health check failed " \
                                      "#{@config.max_health_check_retries} times; the database is not recovering")
        end

        Decision.new(rung: :quarantine, blocker: blocker,
                     reason: "endpoint abandoned after the backoff ladder; the run continues")
      end

      def cooldown_recovered?
        @config.max_health_check_retries.times do
          return true unless @poller.sample&.contended?

          @sleeper.call(@config.backoff_initial_delay_ms / 1000.0)
        end

        false
      end

      # A clean cell resets the ladder for that endpoint, so unrelated contention
      # much later does not inherit an old attempt count and skip straight to
      # quarantine.
      def note_recovery(endpoint_key)
        @mutex.synchronize do
          @backoff_attempts.delete(endpoint_key)
          @consecutive_quarantines = 0
        end
      end

      public :note_recovery

      def backoff_series
        delays = []
        delay = @config.backoff_initial_delay_ms.to_f

        @config.max_backoff_attempts.times do
          delays << [delay, @config.backoff_max_delay_ms].min.round
          delay *= @config.backoff_multiplier
        end

        delays
      end

      # Jitter matters: synchronised retries create their own thundering herd, which
      # is Loadwright causing a second contention event while backing off the first.
      def jittered(delay_ms)
        return delay_ms if @config.backoff_jitter.to_f <= 0

        delay_ms * (1 + (rand * @config.backoff_jitter))
      end

      def lowest_concurrency = Array(@config.concurrency_levels).min || 1

      def step_down_from(concurrency)
        levels = Array(@config.concurrency_levels).sort
        lower = levels.select { |level| level < concurrency.to_i }.max

        lower || lowest_concurrency
      end

      # ---------------------------------------------------------------- attribution

      # "ours" | "external" | "unknown". Unknown is treated as EXTERNAL by callers:
      # blaming an endpoint for a lock we cannot prove was ours is a false positive,
      # and a false positive here destroys trust in every other finding.
      def blocker_attribution(sample)
        return "unknown" if sample.nil?
        return "ours" if sample.blocker_ours?
        return "external" if sample.blocker_external?

        "unknown"
      end

      def degradation_sustained?(endpoint_key, latency_ms)
        return false if latency_ms.nil?

        baseline = baseline_for(endpoint_key)
        return false if baseline.nil? || baseline <= 0

        degraded = latency_ms > (baseline * @config.latency_degradation_multiplier)

        @mutex.synchronize do
          if degraded
            @degradation_windows[endpoint_key] = @degradation_windows.fetch(endpoint_key, 0) + 1
          else
            @degradation_windows[endpoint_key] = 0
          end

          @degradation_windows[endpoint_key] >= @config.degradation_windows_before_backoff
        end
      end

      # ------------------------------------------------------------- the carve-outs

      # Carve-out 1. Blocker was ours, and the same endpoint keeps doing it across
      # cells: the endpoint takes locks it should not, or holds them too long. That
      # is a finding about the endpoint, not just guard telemetry.
      def maybe_record_repeat_offender(endpoint_key, blocker)
        return unless blocker == "ours"

        ours = @events.count { |e| e.endpoint_key == endpoint_key && e.blocker == "ours" }
        return if ours < 2
        return if @findings.any? { |f| f.endpoint_key == endpoint_key && f.kind == :repeat_offender }

        @findings << Finding.new(
          endpoint_key: endpoint_key,
          kind: :repeat_offender,
          detail: "caused contention on #{ours} occasions, and the blocking session was Loadwright's own. " \
                  "This endpoint takes locks it should not, or holds them longer than it needs to.",
          evidence: @events.select { |e| e.endpoint_key == endpoint_key }.map(&:to_h)
        )
      end

      # Carve-out 2.
      def record_connection_leak(endpoint_key, error, concurrency)
        return if @findings.any? { |f| f.endpoint_key == endpoint_key && f.kind == :suspected_connection_leak }

        @findings << Finding.new(
          endpoint_key: endpoint_key,
          kind: :suspected_connection_leak,
          detail: "#{error.class} at concurrency #{concurrency}. Pool exhaustion under real concurrency is " \
                  "load pressure, but with a single request in flight nothing else was competing for a " \
                  "connection — this endpoint almost certainly checks out a connection it never returns. " \
                  "Look for a raw ActiveRecord::Base.connection use, a thread spawned mid-request, or a " \
                  "connection held across an external call.",
          evidence: [{ error_class: error.class.name, concurrency: concurrency }]
        )
      end

      # ------------------------------------------------------------------- plumbing

      def apply_session_timeouts
        return { applied: false, reason: "ActiveRecord is not loaded" } unless defined?(::ActiveRecord::Base)

        connection = ::ActiveRecord::Base.connection
        adapter = connection.adapter_name.to_s.downcase

        statements =
          if adapter.include?("postgres")
            [
              "SET lock_timeout = #{Integer(@config.lock_timeout_ms)}",
              "SET statement_timeout = #{Integer(@config.statement_timeout_ms)}",
              "SET idle_in_transaction_session_timeout = #{Integer(@config.statement_timeout_ms)}"
            ]
          elsif adapter.include?("mysql")
            [
              "SET SESSION innodb_lock_wait_timeout = #{(Integer(@config.lock_timeout_ms) / 1000.0).ceil}",
              "SET SESSION max_execution_time = #{Integer(@config.statement_timeout_ms)}"
            ]
          else
            []
          end

        if statements.empty?
          return {
            applied: false,
            reason: "#{connection.adapter_name} has no session lock/statement timeouts Loadwright can set; " \
                    "a blocked query will not surface as a catchable error and the run may wait longer " \
                    "than lock_timeout_ms suggests"
          }
        end

        statements.each do |statement|
          @mutex.synchronize { @executed_statements << statement }
          connection.execute(statement)
        end

        { applied: true, statements: statements }
      rescue StandardError => e
        { applied: false, reason: "could not set session timeouts: #{e.class}: #{e.message}" }
      end

      def describe(sample)
        return "health could not be sampled" if sample.nil?
        return sample.degraded_reason if sample.degraded_reason && !sample.contended?

        parts = []
        parts << "#{sample.lock_waits} session(s) waiting on locks" if sample.lock_waits.to_i.positive?
        parts << "#{sample.ungranted_locks} ungranted lock(s)" if sample.ungranted_locks.to_i.positive?
        parts << "#{sample.pool_waiting} thread(s) waiting for a connection" if sample.starved?
        if sample.longest_transaction_s.to_f > 5
          parts << "longest transaction #{sample.longest_transaction_s.round(1)}s"
        end

        parts.empty? ? "contended" : parts.join(", ")
      end

      def percentile(samples, fraction)
        sorted = samples.sort
        index = ((sorted.length - 1) * fraction).round

        sorted[index]
      end
    end
  end
end

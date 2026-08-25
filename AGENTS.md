# AGENTS.md — Loadwright Operational Reference for AI Agents

```yaml
doc_type: agent_operational_reference
audience: ai_agents_only
gem: loadwright
purpose: configure, run, and interpret Loadwright inside a user's Rails app
human_readable: not_required
authoritative_for: [setup, configuration, troubleshooting, result_interpretation]
not_authoritative_for: [gem_internals]
gem_internals_see: .claude/skills/loadwright-development/
STATUS: IMPLEMENTED__VERIFIED_AGAINST_THE_BUILD
status_note: |
  Every command, config key, report state, exit code, and capability pairing
  below has been checked against the implementation, and the config-key half
  is enforced by a drift spec that fails the build when this file names a key
  that does not exist.
  Two things are still true and still matter: this file describes a
  pre-1.0 gem, and if observed behaviour differs from this file, THE GEM WINS
  and this file is stale — say so rather than insisting.
verified_at: 2026-08-24
```

## 0. READ_ORDER

```
1. Section 1 (INVARIANTS) — never skip, never override
2. Section 2 (WHAT_IT_IS) — 30 seconds of context
3. Jump directly to the section matching the user's request via Section 3
```

---

## 1. INVARIANTS — VIOLATION IS ALWAYS AN ERROR

```yaml
INV-01:
  rule: Never set allow_production=true on the user's behalf.
  detail: >
    Only the human sets this, in the initializer, having read what it
    means. If a user asks you to enable it, explain the four-layer gate
    and let them decide. Do not "helpfully" pre-configure it.
  violation_severity: critical

INV-02:
  rule: Never set allow_mutating_requests=true without explicit user consent
        in the current conversation.
  detail: >
    Mutating load can delete/modify real dev data and trigger side effects.
    Default false exists for a reason.
  violation_severity: critical

INV-03:
  rule: Never set http_target_url to a non-loopback host on the user's
        behalf.
  detail: >
    Remote targets bypass the local environment gate — the receiving
    process may be a different environment entirely. Requires
    allow_remote_http_target=true, set by the human.
  violation_severity: critical

INV-04:
  rule: Never remove `if defined?(Loadwright)` from the generated
        initializer.
  detail: >
    Rails loads initializers in ALL environments; the gem is dev/test-only.
    Removing the guard raises NameError and breaks production boot.
  violation_severity: critical

INV-05:
  rule: Never set seed_cleanup_strategy to anything that truncates tables.
  detail: Destroys the user's local data. :delete_created_rows is default.
  violation_severity: high

INV-06:
  rule: Never disable side-effect containment to "make the numbers more
        realistic."
  detail: >
    suppress_mail_delivery / suppress_background_jobs / block_outbound_http
    prevent real emails, jobs, and third-party calls from a load test.
    Disclose the skew in your interpretation instead.
  violation_severity: high

INV-07:
  rule: Never report an `inconclusive` endpoint as healthy or passing.
  detail: >
    Three states exist: healthy | has_findings | inconclusive.
    inconclusive means "could not validly measure" — it is NOT a pass.
  violation_severity: high

INV-08:
  rule: Never present :in_process concurrency numbers as capacity findings.
  detail: >
    :in_process has no real thread pool. Concurrency-dependent findings are
    marked unavailable. Do not reinterpret "unavailable" as "fine".
  violation_severity: high

INV-09:
  rule: Never call a latency delta a regression without checking it cleared
        both regression_threshold_pct AND the measured noise floor.
  detail: Laptop latency moves 10-20% run-to-run. Query counts are signal.
  violation_severity: medium

INV-10:
  rule: Never paste raw report contents into a shared channel without
        checking redaction settings.
  detail: Reports may contain SQL, bind values, request/response bodies.
  violation_severity: high

INV-11:
  rule: Never suggest killing/terminating DB sessions to resolve contention.
  detail: >
    Loadwright retreats from contention by design. If a user asks for a
    "force" or "cleanup" option, the answer is no — reduce load instead.
  violation_severity: critical
  scope_note: >
    INV-11 is about DATABASE SESSIONS. It does not conflict with DIAG-10e, where
    orphan reaping terminates a leftover server process. Two different scopes:
    Loadwright terminates its OWN orphaned child processes, recorded in its OWN
    per-run directories, identified by PID + process start time + hostname. It
    never terminates a database session, never terminates a process it did not
    spawn, and never kills on a PID match alone. If a user or a diff asks for
    either of the latter, the answer is still no.

INV-12:
  rule: >
    Never read an unavailable Measurement as zero, absent, or fine. It carries a
    REASON, and the reason is the finding.
  detail: |
    Measurement is tri-state and never nullable: a value, or unavailable(reason).
    "0 queries" and "query count could not be measured" are opposite claims and
    an agent that flattens them produces exactly the confidently-wrong all-clear
    the three-state outcome model exists to prevent.

      WRONG: "connection pool exhaustion: 0 -- no pool pressure detected"
      RIGHT: "connection pool exhaustion: not measured (in-process execution has
              no server thread pool). Re-run with --mode http to answer this."

    Same rule for the run's own summary: an endpoint whose signals were mostly
    unavailable is `inconclusive`, not `healthy`, and must never be counted in a
    healthy total. See INV-06 and section 9.
  violation_severity: critical

INV-13:
  rule: >
    Never quote a capability, finding, or exit code from `execution_mode` alone.
    Read the run's own metadata.
  detail: |
    execution_mode is what was REQUESTED. Capability is what was ACHIEVED, and
    an :http run against a target that would not answer the collector gets the
    same transport and far less capability. metadata.capabilities states the
    actual transport+collector pairing, per window, with the cause of every
    downgrade. Section 5.1 is keyed that way for this reason.
  violation_severity: high
```

---

## 2. WHAT_IT_IS

```yaml
one_line: >
  Local diagnostic gem that discovers a Rails API's endpoints, seeds data at
  increasing scale via FactoryBot, drives load, and reports query/latency/
  memory/contention findings per endpoint.
category: local developer diagnostic tool
NOT: [ci_gate, apm, capacity_planning_tool, production_tool]
default_execution_mode: :in_process
default_posture: report-only, non-blocking, dev/test only
primary_output: self-contained HTML report + persisted JSON run record
```

### 2.1 Relationship to other tools (use when a user asks "why not just X")

```yaml
bullet:              dev-time N+1 detection, continuous, no load/scale dimension
prosopite:           same niche as bullet, fewer false pos/neg, API/job friendly
n_plus_one_control:  CI regression assertions; USE THIS for CI gating, not Loadwright
rack_mini_profiler:  per-request profiling incl. flamegraphs
pghero:              DB-level slow queries + missing indexes, no endpoint attribution
apm_tools:           production reality, real traffic, trends
k6_vegeta_wrk:       real capacity/load testing at scale
loadwright_niche: >
  Combines endpoint discovery + data scaling + query/response correlation +
  contention safety in one local run. Complements the above; replaces none.
```

---

## 3. REQUEST_ROUTER

Match the user's intent, go to the section.

```yaml
"install / set up / add to my app":            -> S4
"which mode should I use":                      -> S5
"configure it for my app":                      -> S6
"how do I run it":                              -> S7
"it's not working / errors / weird output":     -> S8  (LARGEST SECTION)
"what does this report mean":                   -> S9
"did my change make things worse":              -> S10
"is this safe to run":                          -> S11
"tune contention / it's too slow / too twitchy":-> S12
"write a config for CI":                        -> S13 (mostly: don't)
unclear:                                        -> ask ONE clarifying question, then S4
```

---

## 4. SETUP_PROCEDURE

```yaml
step_0_requirements:
  ruby: ">= 3.1"
  rails: ">= 7.0"
  why_rails_7: |
    Per-request metric correlation uses ActiveSupport::IsolatedExecutionState,
    added in Rails 7.0, which honours the host app's configured
    isolation_level. There is no 6.1 fallback: hand-rolling fiber/thread
    locals gets isolation subtly wrong under exactly the concurrency this gem
    generates, in the code path where a wrong answer is least detectable.
  on_older_rails: |
    Do not attempt a workaround. Tell the user Loadwright requires Rails 7.0+.
  verify: ruby -e 'require "rails"; puts Rails.version'

step_1_gemfile:
  action: add to development+test group ONLY
  code: |
    group :development, :test do
      gem "loadwright"
    end
  why: |
    Production must never load it. This is also why the initializer needs
    the `if defined?` guard (INV-04).
  verify: bundle list | grep loadwright

step_2_generate:
  command: bundle exec rails generate loadwright:install
  creates:
    - config/initializers/loadwright.rb
    - .gitignore entries for tmp/loadwright/
  verify: |
    head -20 config/initializers/loadwright.rb | grep -q 'if defined?(Loadwright)'
    # If this fails, STOP. Do not proceed. See INV-04.

step_3_minimum_viable_config:
  required_keys_before_first_run:
    - auth_token_provider   # unless the API is fully public
    - factory_map           # unless you only want route-level smoke testing
  auth_login_alternative: >
    config.auth_login is usually easier to get right than auth_token_provider,
    especially for session/cookie apps where the alternative is hand-assembling a
    valid cookie. It names the login request the app's own clients make:
      path, credentials (a LIST -- that is how multi-identity traffic happens),
      and extract: { json: "token" } or { header: "Set-Cookie" }.
    Set one or the other; both is refused at startup, not resolved by precedence.
    The login requests are setup: never measured, never reported as endpoints.

  optional_but_high_value:
    - openapi_spec_paths    # if the app has a swagger/OpenAPI doc
    - integration_spec_paths # if it has request specs
  note: >
    Leaving auth_token_provider unset is the #1 cause of a first run
    returning all-inconclusive. See S8.DIAG-01.

step_4_dry_run_first:
  command: bundle exec loadwright run --dry-run
  expect: |
    Prints resolved endpoint list, scale matrix, request counts, whether any
    are mutating, estimated duration, worst-case backoff budget.
    Sends ZERO requests.
  gate: |
    Review the endpoint list WITH the user before executing. If the count is
    unexpectedly large or includes admin/destructive paths, fix
    excluded_paths before running for real.

step_5_first_real_run:
  command: bundle exec loadwright run --execute
  recommended_first_config:
    scale_factors: [1, 10]
    concurrency_levels: [1]
    requests_per_endpoint_per_level: 25
  why: >
    Fast feedback loop. Confirms auth, discovery, seeding, and path-param
    resolution all work before committing to a long sweep. Scale up after
    the first clean run, not before.
```

---

## 5. MODE_SELECTION_DECISION_TREE

```yaml
question_being_asked:

  "does this endpoint have an N+1 / over-fetch / missing pagination?":
    mode: :in_process
    rationale: single-request properties; concurrency adds nothing
    confidence: high

  "is my query structure correct after this refactor?":
    mode: :in_process
    confidence: high

  "did query counts regress between branches?":
    mode: :in_process
    rationale: query counts are mode-independent AND deterministic; faster mode wins
    confidence: high

  "is my connection pool sized right for my Puma config?":
    mode: :http
    rationale: requires real server threads; :in_process CANNOT answer this
    confidence: high

  "where does this endpoint fall over — 10 users? 50?":
    mode: :http
    rationale: :in_process concurrency numbers are meaningless here
    confidence: high

  "what latency will my clients actually see?":
    mode: :http
    rationale: :in_process excludes socket, HTTP parsing, Puma queueing
    confidence: high

  "memory bloat / GC pressure investigation":
    mode: :http
    rationale: clean process-level attribution; harness not in the same heap
    confidence: medium

  unsure_or_unstated:
    mode: :in_process
    rationale: default; zero setup; covers the majority of findings
    then: >
      If results show latency concerns or the user asks about concurrency,
      recommend re-running in :http.

MODE_SUMMARY_FOR_USERS: >
  :in_process finds correctness problems in query structure.
  :http finds capacity problems.
  Most questions are the first kind.
```

### 5.1 Capability matrix — KEYED BY TRANSPORT + COLLECTOR, NOT BY MODE

**READ THIS BEFORE USING THE TABLE.** Capability is a property of the
COLLECTOR, not of `execution_mode`. An `:http` run against a target that does
not load the gem has the same transport as a fully instrumented one and
dramatically less capability. Keying this table by mode — as an earlier version
did — reports confident numbers for things that run never measured.

So there are three columns, not two. `execution_mode = :http` can land in
EITHER of the last two, and which one is decided at runtime by whether the
collector middleware answers:

- `in_process + direct` — the default. The harness shares the app's process.
- `http + middleware` — Loadwright booted the server, so it could arm the
  collector with a per-run secret.
- `http + external` — **the degraded remote case.** `http_target_url` points at
  a server Loadwright did not boot, so nothing could get a secret into that
  process. Only response-derived signals survive.

Never report a signal from the wrong column. Read the run's own
`metadata.capabilities`, which states the actual pairing and the reason for
every downgrade — do not infer it from the configured mode.

```yaml
# signal:                      in_process+direct  http+middleware  http+external
  n_plus_one_pattern_match:    available          available        UNAVAILABLE
  n_plus_one_slope:            available          available        UNAVAILABLE
  queries_per_returned_record: available          available        UNAVAILABLE
  over_fetch_hint:             available          available        UNAVAILABLE
  payload_growth_pagination:   available          available        available
  response_validity_gate:      available          available        available
  time_breakdown_db_view_gc:   available          available        UNAVAILABLE
  explain_index_analysis:      available          available        UNAVAILABLE
  cold_vs_warm_cache:          available          available        available
  latency_under_concurrency:   UNAVAILABLE        available        available
  connection_pool_exhaustion:  UNAVAILABLE        UNAVAILABLE      UNAVAILABLE
  pool_vs_threads_static_check: partial           available        UNAVAILABLE
  true_client_latency:         UNAVAILABLE        available        available
  clean_memory_attribution:    UNAVAILABLE        UNAVAILABLE      UNAVAILABLE
```

```yaml
unavailability_reasons:
  no_collector_middleware: |
    "no collector middleware; query data cannot be retrieved from the target"
    Applies to the whole http+external column. Everything derived from the
    app's own instrumentation is gone; response-derived signals survive.
  no_real_threads: |
    "in-process execution has no server thread pool; use execution_mode = :http"
    NOT re-enabled by allow_in_process_threading. Threads inside one process
    sharing a GVL do not measure anything a user would experience.
  no_app_process: |
    "harness shares the app's process; use execution_mode = :http"
    The in-process reason for clean_memory_attribution. Superseded in every mode by
    not_collected_yet below.
  not_collected_yet: |
    "allocation figures are not collected yet..." / "pool samples are not collected yet..."
    MEMORY AND CONNECTION POOL ARE NOT MEASURED IN ANY MODE. MemoryTracker and
    ConnectionPoolTracker exist, are specced, and are instantiated by nothing in a
    run -- so no allocation figure and no pool sample reaches any report.
    This is the gem's own unfinished work, not a property of the transport.

    AGENT CONSEQUENCE: never tell a user this tool measured their memory usage or
    their connection pool utilisation. It does not. `pool_vs_threads_static_check`
    still works and is a real finding -- it compares configured server threads
    against pool size, per process -- but it is a STATIC config comparison, not an
    observation of pressure. Do not present it as one.
    Contention that manifests as pool-exhaustion ERRORS is still caught, separately,
    by the resource guard (see section 8) -- that path is unaffected.

partial_is_a_third_state: |
  pool_vs_threads_static_check under in_process is "partial": the STATIC config
  comparison (threads > pool, PER PROCESS) works; the observed-contention half
  does not. Report the static half and say the observed half is missing. Do not
  round `partial` to either `available` or `unavailable`.

CAPABILITY_IS_NOT_FIXED_FOR_A_RUN:
  rule: >
    Capability degrades MID-RUN. Middleware can stop responding; the app process
    can die. Results stay attributed to the capability actually in effect when
    they were collected, and the report renders capability PER WINDOW with the
    cause of each downgrade.
  agent_consequence: >
    Do not summarise a run's capability as one thing if metadata shows more than
    one epoch. Say which windows lost which signals and why. See DIAG-17.
```

### 5.2 Known measurement gaps — state these, do not paper over them

```yaml
GAP-01_async_query_attribution:
  affects: [n_plus_one_pattern_match, n_plus_one_slope, queries_per_returned_record]
  modes: [in_process, http]
  cause: |
    Per-request correlation tags queries via a fiber-local request id. Queries
    issued from a DIFFERENT fiber or thread than the one handling the request
    do not carry that id. In practice this means:
      - ActiveRecord load_async
      - threads the application spawns during a request
      - any explicit Concurrent::Future / Thread.new in controller or model code
  effect: those queries are UNDER-ATTRIBUTED — the endpoint's query count is
          lower than reality, so an N+1 may be undercounted or missed entirely
  agent_instruction: |
    If the user's app uses load_async or spawns threads per request, say so
    explicitly when reporting query counts. Do NOT present a clean query count
    for such an endpoint as proof there is no N+1.
  not_a_bug_in: the app; this is a limitation of fiber-local correlation

GAP-02_capability_can_degrade_mid_run:
  cause: |
    The collector middleware can stop responding mid-run, and under :http the
    app process can die outright. Capability is recorded per window, not once
    per run.
  agent_instruction: |
    If a report shows a capability downgrade, findings collected BEFORE and
    AFTER the downgrade are not equally trustworthy. Report the affected
    window rather than summarising the run as a single confidence level.
```

---

## 6. CONFIGURATION_COOKBOOK

Task -> exact keys. All keys live in `config/initializers/loadwright.rb`
inside the `if defined?(Loadwright)` block.

```yaml
TASK: "only test a few endpoints"
  set:
    included_paths: [%r{^/api/v1/orders}, %r{^/api/v1/invoices}]
  note: included_paths is an allowlist; nil means no restriction

TASK: "skip admin and health endpoints"
  set:
    excluded_paths: [%r{^/admin/}, %r{^/health}, %r{^/rails/}]
  note: these three are already default; extend rather than replace

TASK: "app uses JWT bearer auth"
  set:
    auth_strategy: :bearer_token
    auth_token_provider: "-> { JwtIssuer.for(User.first) }"
  warning: >
    Returning ONE token means all traffic is one user — identical cache
    keys, single-tenant scoping, row-lock contention on one user's rows.
    Prefer returning a collection.

TASK: "multi-tenant app / realistic identity spread"
  set:
    auth_token_provider: "-> { User.limit(5).map { |u| JwtIssuer.for(u) } }"
    test_identity_pool_size: 5
  why: single-tenant traffic can make a badly-scoped query look fine

TASK: "app has an OpenAPI doc"
  set:
    openapi_spec_paths: ["Rails.root.join('swagger/v1/swagger.yaml')"]
    require_schema_valid_response: true
  bonus: enables response contract validation, not just discovery

TASK: "app has request specs but no OpenAPI doc"
  set:
    integration_spec_paths: ["Rails.root.join('spec/requests')"]
  procedure: |
    Recording mode must run once to capture requests:
      bundle exec loadwright record --specs spec/requests
    This runs the specs and captures every real request they made.
    Re-run after adding new endpoints.
  advantage: >
    Captured requests are proven-valid, including complex nested params an
    OpenAPI doc may not capture or may have drifted from.

TASK: "nested routes return 404s"
  cause: path params unresolved (placeholder IDs from OpenAPI examples)
  set:
    factory_map: '{"post" => {factory: :post}}'   # primary fix: seed the resource
    path_param_overrides: '{"/api/v1/posts/{slug}" => {slug: -> { Post.first&.slug }}}'
  see: S8.DIAG-03

TASK: "seeding fails on uniqueness"
  fix_location: the user's FactoryBot factory, NOT Loadwright config
  correct_fix: |
    factory :user do
      sequence(:email) { |n| "user#{n}@example.com" }
    end
  do_not: >
    Do not reach for unique_field_generator as the fix. It exists only for
    resources with no factory at all. Working around a missing sequence
    produces data that does not match how the app is actually used.

TASK: "run is too slow"
  try_in_order:
    - reduce scale_factors: [1, 10]
    - reduce concurrency_levels: [1]
    - narrow included_paths
    - reduce requests_per_endpoint_per_level (but see S9.4 percentile floors)
    - switch execution_mode to :in_process
  do_not: raise max_error_rate_before_abort or loosen the contention guard

TASK: "shared development database with teammates"
  set:
    contention_profile: :conservative
    concurrency_levels: [1]
    scale_factors: [1, 10]
    seed_cleanup_strategy: :delete_created_rows
  also_tell_user: >
    Seeding writes real rows to a database other people are using. Confirm
    they're okay with that before running.

TASK: "throwaway docker database, find problems fast"
  set:
    contention_profile: :aggressive
    scale_factors: [1, 10, 50, 200]
    concurrency_levels: [1, 5, 20]
    execution_mode: :http

TASK: "test POST/PUT/DELETE endpoints"
  set:
    allow_mutating_requests: true
  REQUIRED_FIRST: explicit user consent in this conversation (INV-02)
  also_verify:
    - suppress_mail_delivery: true
    - suppress_background_jobs: true
    - block_outbound_http: true
  warn_user_about: >
    Repeated writes confound their own measurement — request 500 runs
    against a table with 499 more rows than request 1. Latency drift may
    reflect data growth, not concurrency.

TASK: "want percentiles to be meaningful"
  set:
    requests_per_endpoint_per_level: 500   # p99 needs several hundred samples
  note: >
    Loadwright OMITS percentiles the sample size can't support rather than
    printing noise. If you see "insufficient samples for p99", this is the
    fix. See min_samples_for_percentiles.

TASK: "reports must not contain sensitive data"
  set:
    honor_rails_filter_parameters: true    # default
    redact_sql_bind_values: true           # default
    include_response_bodies: false         # default
    redact_additional_patterns: [/ssn/i, /account_number/i]
  verify: grep the generated report for a known-sensitive value before sharing
```

---

## 7. RUN_COMMANDS

```yaml
dry_run:        bundle exec loadwright run --dry-run
execute:        bundle exec loadwright run --execute
single_path:    bundle exec loadwright run --execute --only '/api/v1/orders'
record_specs:   bundle exec loadwright record --specs spec/requests
list_runs:      bundle exec loadwright runs list
set_baseline:   bundle exec loadwright baseline set <run_id>
compare:        bundle exec loadwright compare <run_a> <run_b>
compare_base:   bundle exec loadwright compare --baseline

implemented_now: [run, record, runs, baseline, compare]
still_stubbed:   []

run_exit_codes:
  0: the run completed. Findings may still be present -- see below.
  1: the run completed and something the user asked to fail on was found
     (a latency budget exceeded, an N+1 when fail_on_n_plus_one is true), OR
     the run aborted partway (circuit breaker, contention) and its report is partial.
  3: REFUSED. Nothing ran. The safety guard declined, containment could not be
     enforced, the app would not boot, or discovery produced no exercisable
     endpoint. NEVER read this as a clean result -- no endpoint was measured.
  130: interrupted by SIGINT/SIGTERM. Seeded rows were cleaned up and a partial
     report was written.

run_exit_code_caveats:
  inconclusive_does_not_fail: >
    An endpoint that could not be validly measured is a COVERAGE gap, not a
    defect, and never contributes to a non-zero exit code. So exit 0 does NOT
    mean "the API is healthy" -- read the three-state summary, never the exit
    code alone. This is the confidently-wrong-all-clear failure INV-* exists to
    prevent, applied to scripting.
  advisory_findings_do_not_fail: >
    over_fetch_hint is advisory and never fails the run, per response-analysis.md.
  exit_code_is_a_convenience: >
    reporting.md is explicit that this is not the tool's interface. For a real CI
    gate the honest answer is still n_plus_one_control.

compare_exit_codes:
  0: comparable, and either no regressions or fail_on_regression is false
  1: comparable, regressions found, and fail_on_regression is true
  2: NOT COMPARABLE — the runs diverge on a measurement dimension.
     This is an ERROR, never a silent pass. Do not retry with different
     flags; the fix is to re-run one side under matching config.

flags:
  --dry-run:                 resolve everything, send zero requests
  --execute:                 actually issue requests
  --i-understand-the-risk:   required for any non-default-environment run
  --only PATTERN:            restrict to matching paths
  --mode in_process|http:    override config.execution_mode for this run

ALWAYS_DRY_RUN_FIRST: true   # agent behaviour, NOT a tool-enforced gate
enforcement: >
  The tool DEFAULTS to a dry run; it does not require one. --execute overrides it
  in the same invocation and nothing records whether a dry run ever happened. This
  key is an instruction to you, not a guarantee to repeat to the user.
reason: >
  Shows the endpoint list, mutating-request count, estimated duration, and
  worst-case backoff budget before anything is sent. Cheap insurance.

dry_run_writes_no_report: true
dry_run_note: >
  --dry-run prints the matrix to the terminal and writes NO report file and NO
  history record, because it issues zero requests -- every endpoint in such a
  report would be `inconclusive` and every measurement absent. Do not go looking
  for a report file after a dry run, and do not tell a user one exists.

run_prerequisites:
  working_directory: >
    `loadwright run` boots the host app itself by loading config/environment.rb
    from the CURRENT DIRECTORY. It must be run from the Rails application root.
    Exit 3 with "no config/environment.rb" means the wrong directory, not a
    broken install.
  configuration_source: >
    config/initializers/loadwright.rb is what configures the run; it is evaluated
    as part of that boot. --mode is applied AFTER it, so the flag beats the file.

long_run_confirmation: >
  Before issuing requests, the estimated duration is printed and, above
  long_run_confirmation_threshold_minutes, confirmed interactively. With stdin
  not a terminal the run PROCEEDS with a warning rather than refusing -- unlike
  the production gate, which refuses when it cannot prompt. Do not conflate the
  two: this one is about someone's afternoon, that one is about irreversible harm.

interrupt_behavior: >
  SIGINT (Ctrl-C) is trapped: stops issuing requests, tears down any booted
  server, cleans up seeded rows, writes a partial report AND a partial run
  history record. Interrupting is safe. Tell users this — they often fear it
  isn't.
```

### 7b. COMPARISON RULES

```yaml
COMP-01:
  rule: Query count deltas are the primary signal; latency deltas are mostly noise.
  detail: >
    A query count going 3 -> 47 is unambiguous and reproducible on any machine,
    and gets NO statistical treatment. Laptop latency moves 10-20% between
    identical runs, so a latency delta must clear BOTH regression_threshold_pct
    AND the measured noise floor. Anything below is labelled "within noise" —
    shown, never called a regression.

COMP-02:
  rule: The comparability gate refuses rather than misleads, and names the dimension.
  dimensions_checked:
    - resolved config values (execution_mode, scale_factors, concurrency_levels,
      requests_per_endpoint_per_level, warmup_requests, page_size_sweep,
      containment settings, disable_query_cache_during_run, seed_cleanup_strategy)
    - the app's OWN default page size, observed per endpoint — NOT in the config
      fingerprint, because the seed-scale sweep sends no page-size parameter
    - CapabilityProfile: a run that lost query collection mid-way has the same
      config fingerprint and less data
  capability_handling: >
    Capability mismatch EXCLUDES the affected metric and names it, rather than
    refusing the whole comparison. Config or page-size mismatch refuses outright.
  observed_page_size_is_run_level_only: >
    The observed-page-size dimension is sampled from the LARGEST scale factor's
    seed-scale cells only. Record counts can still move in page-size-sweep cells, or
    at smaller scales, without tripping it -- which is what COMP-03b covers per cell.
    The two are complementary; neither replaces the other.

request_created_row_cleanup: >
  Rows the APP creates answering a request -- a POST's records, or a GET that writes
  an audit row -- are now cleaned up too, via the same pre-seed watermark the
  factories' associated rows use. Strictly id-bounded, never a TRUNCATE, and
  incapable of reaching a row that existed before the run. Governed by
  config.cleanup_request_created_rows (default true).
  PRECISION MATTERS HERE: turning it off narrows the sweep to tables the factories
  wrote to; it does not stop cleanup. seed_cleanup_strategy = :leave is the setting
  that cleans up nothing. Do not tell a user the flag makes a shared database safe.

metrics_actually_compared: [queries, records, bytes, latency_ms]
metrics_NOT_compared:
  allocations: >
    Not persisted per cell, so no allocation delta exists. Do NOT tell a user their
    memory usage was compared between two runs -- nothing compared it. This is why
    clean_memory_attribution gates nothing.

COMP-03:
  rule: A finding that disappeared because the endpoint became inconclusive is NOT a fix.
  detail: >
    healthy/has_findings -> inconclusive is its own event: the endpoint became
    unmeasurable, which is neither an improvement nor a regression. Never report
    it as "resolved". Loadwright marks these `resolved: false` with a note.

COMP-03b:
  rule: >
    A query-count change whose RECORD COUNT also moved is not a regression and not
    an improvement. Never report it as either.
  detail: |
    A query count only means something next to the number of records that produced
    it. Narrow a scope, break a filter, or cap a page size, and a collection returns
    5 records instead of 30 -- queries fall 31 -> 6 and it looks like the N+1 got
    fixed. It did not: that is the same queries-per-record over less data, and the
    endpoint is arguably broken.
  how_it_appears: |
    verdict: :unattributable, rendered in its own report section, "Changed, but not
    like-for-like", placed directly after Regressions and BEFORE anything that reads
    as good news. A drop in returned records at an unchanged scale factor and page
    size is separately reported as a REGRESSION in its own right.
  agent_instruction: >
    If you see a query drop in that section, do not tell the user their query count
    improved. Tell them the endpoint returned fewer records and that the two facts
    have to be read together. Absent record counts on BOTH sides are not a change --
    error responses and older run records carry none.

COMP-04:
  rule: The noise floor is measured, not assumed.
  how: >
    `baseline set` looks for a second run on the same commit with the same config
    fingerprint and records the spread between them as the noise floor. Without
    one it says so and falls back to regression_threshold_pct alone. Advise
    running the suite twice on the baseline commit.
```

---

## 8. TROUBLESHOOTING — DIAGNOSTIC TABLE

This is the highest-value section. Match symptom exactly.

```yaml
DIAG-01:
  symptom: "Every endpoint reports inconclusive; uniform 401 or 403"
  version_note: >
    Before 0.0.2 this could also be the tool's own fault: the identity pool was never
    resolved, so a correctly configured auth_token_provider was never actually sent.
    If a user reports this on an older version, check the version before debugging
    their credentials.
  probability: VERY_HIGH  # most common first-run failure
  cause: auth_token_provider not configured or returning an invalid token
  second_cause_check_it_before_concluding: >
    Rails' HostAuthorization middleware answers 403 BEFORE the request reaches the
    app, and from outside it is indistinguishable from an auth failure. Loadwright
    sends Host: localhost under :in_process precisely because that is on Rails'
    development allow-list -- but an app with a custom Rails host allow-list excluding
    it will 403 every request, including endpoints that need no auth at all.
    TELL THEM APART: if endpoints that require NO authentication also return 403,
    it is the host guard, not the token. Chasing auth there wastes the user's time
    on something that was never the problem.
    NOTE: the host allow-list is a RAILS setting (`Rails.application.config`
    -> `hosts`), NOT a Loadwright config key. Do not try to set it through
    Loadwright.configure; it does not exist there and would silently do nothing.
  fix: |
    1. Verify the lambda returns a usable token:
       rails runner 'puts Loadwright.config.auth_token_provider.call.inspect'
    2. Confirm auth_strategy matches the app (:bearer_token vs :session)
    3. Check default_headers includes anything else the API requires
    4. If public endpoints 403 too, check the app's Rails host allow-list
       (a `hosts` entry in config/environments/*.rb), and set
       config.default_headers["Host"] to a host that app permits
  do_not: >
    Do not conclude the API is broken. Do not disable
    require_successful_response to "get results" — that produces
    measurements of the 403 error path.
  note: >
    Loadwright names this itself when 80%+ of at least three endpoints return
    ONLY 401/403: the endpoints are marked inconclusive with reason
    `auth_failed`, whose explanation points at auth_token_provider, and a
    run-level diagnosis is printed. Below that bar it says nothing, because an
    API with an admin section is not a misconfiguration.

DIAG-02:
  symptom: "Cluster of 429s / Retry-After headers / run mostly inconclusive"
  cause: rate limiting (Rack::Attack or similar) throttling the load test
  fix: |
    Allowlist Loadwright's requests in the rate limiter for dev/test, e.g.
    a safelist on a header Loadwright sends, or disable the throttle in the
    dev environment.
  note: >
    Loadwright detects and names this itself, at the RUN level: a cluster of
    429s, or Retry-After / RateLimit-* headers, produces a plain-language
    diagnosis in run metadata and on stdout, and the affected endpoints are
    marked inconclusive with reason `rate_limited` rather than the generic
    `unsuccessful_status`. If a throttled run does NOT say so, report the gap.

DIAG-03:
  symptom: "Nested endpoints 404; /posts/{id}/... all fail"
  cause: path params unresolved — OpenAPI example IDs don't exist in the DB
  fix_order:
    1: add the resource to factory_map so real IDs get seeded
    2: add path_param_overrides for slugs/UUIDs/composite keys
    3: if neither works, exclude the path and note the limitation
  never: send placeholder IDs and report the resulting 404 as a result

DIAG-04:
  symptom: "Endpoint returns [] but data was seeded"
  cause: seeded records don't match the endpoint's scope
  common_reasons: [wrong tenant, published/draft flag, soft-deleted,
                   ownership association, default scope]
  fix: add a factory trait that satisfies the scope, e.g.
       factory_map: '{"post" => {factory: :post, trait: :published}}'
  status_meaning: inconclusive — NOT a fast healthy endpoint (INV-07)

DIAG-05:
  symptom: "Run aborts immediately before any request"
  causes_in_order:
    1: environment not in enabled_environments -> check Rails.env
    2: baseline health check failed -> DB already contended (migration
       running? long transaction? another load test?)
    3: side-effect containment unenforceable -> missing webmock, or a
       custom mailer bypassing ActionMailer
  diagnose: read the abort reason in the partial report metadata; it names
            which gate fired

DIAG-06:
  symptom: "Production boot fails with NameError: uninitialized constant Loadwright"
  cause: initializer missing the `if defined?(Loadwright)` guard (INV-04)
  fix: wrap the entire Loadwright.configure block in `if defined?(Loadwright)`
  severity: CRITICAL — this breaks deploys
  prevention: never hand-edit the guard out; regenerate if unsure

DIAG-07:
  symptom: "Known-bad endpoint shows no N+1"
  causes_in_order:
    1: query cache enabled -> set disable_query_cache_during_run: true
       (it dedupes identical queries within a request, hiding the N+1)
    2: endpoint is paginated -> seeded-scale slope is blind to this; the
       returned-record-count slope and page_size_sweep handle it. Verify
       page_size_parameters matches the app's actual param name.
    3: result size can't be varied -> finding will read "N+1 slope not
       measurable" rather than "flat"
  never: conclude the endpoint is clean without checking all three

DIAG-08:
  symptom: "Endpoints keep getting quarantined"
  cause: contention guard escalating to Rung 3
  diagnose_first: >
    Check whether the blocking session was OURS or EXTERNAL. If external
    (a migration, a teammate, a Sidekiq worker), the endpoint is fine and
    the result is inconclusive — do not report it as an endpoint problem.
  fixes_if_ours:
    - contention_profile: :conservative
    - lower concurrency_levels
    - lower scale_factors
    - raise latency_degradation_multiplier (less twitchy)
  see: S12

DIAG-09:
  symptom: "Run appears hung"
  likely_cause: backoff, not a hang
  diagnose: |
    Loadwright prints the worst-case backoff budget at start. Defaults:
    ~3.75s per contention event, ~26s before global abort. If configured
    values are much higher, the run may legitimately wait minutes.
  fix: lower backoff_max_delay_ms / max_backoff_attempts, or Ctrl-C (safe)

DIAG-10:
  symptom: "Run aborts with many lock-timeout errors in the log"
  cause: THIS SHOULD NOT HAPPEN — contention errors are excluded from the
         circuit breaker's error rate by classification, not by tuning
  explanation: >
    The circuit breaker owns "this endpoint is broken" (wrong auth, missing
    route, 500s). The contention guard owns "the database is under pressure"
    (lock waits, pool timeouts, statement timeouts). Tier 1 contention
    exception classes are routed to the guard and excluded from the breaker's
    numerator, so contention cannot trip the breaker.
  fix: |
    Do NOT reflexively raise max_error_rate_before_abort. First check the
    report metadata, which records the two error counts separately. If
    contention errors are appearing in the breaker's count, that is a
    classification bug — report it rather than tuning around it.
    Raise max_error_rate_before_abort only if the endpoints themselves are
    genuinely returning non-contention errors at a high rate.
  do_not: loosen the contention guard — that's the wrong lever

DIAG-10b:
  symptom: "ConnectionTimeoutError reported at concurrency level 1"
  cause: almost certainly an application CONNECTION LEAK, not load pressure
  explanation: >
    Pool exhaustion under real concurrency is load. The same error with a
    single request in flight means the endpoint checked out a connection it
    never returned. The concurrency level is what distinguishes them, and
    Loadwright classifies on it: at concurrency 1 this is an endpoint finding,
    not a contention event.
  fix: look for a connection checked out and not released — a raw
       ActiveRecord::Base.connection use, a thread spawned mid-request, or a
       connection held across an external call

DIAG-10c:
  symptom: "Same endpoint quarantined repeatedly across cells"
  cause: repeat offender — this is an endpoint finding, not just guard noise
  explanation: >
    When the blocking session is OURS and the same endpoint triggers
    contention across multiple cells, the endpoint takes locks it should not
    or holds them too long. Loadwright reports this as an endpoint finding
    alongside the contention events.
  do_not: report this endpoint as merely "unmeasurable" — the repetition is
          itself the finding

DIAG-10d:
  symptom: "Run aborted on the circuit breaker AND the report shows a high
            contention count"
  cause: TWO INDEPENDENT THINGS HAPPENED. Both counts are real and neither
         caused the other.
  explanation: >
    The breaker aborted because endpoints were returning genuine
    non-contention errors. Separately, the guard was retreating from database
    pressure. Because Tier 1 contention is excluded from the breaker's
    numerator, the contention count contributed NOTHING to the abort — the
    abort is attributable entirely to the errors count.
    Before the breaker/guard split this arrived as one confusing number and
    the workaround was to raise the threshold. It is now two numbers, and
    reading them as one produces the wrong fix.
  fix: |
    Read the two counts separately from report metadata. `errors` and
    `error_rate` are the breaker's; `contention_events` is the guard's, and
    `contention_excluded_from_error_rate: true` states the relationship.
    1. Diagnose the abort from the errors alone — usually auth (DIAG-01),
       a missing route, or 500s. That is what aborted the run.
    2. Diagnose the contention separately, and only if it was excessive:
       check whether the blocker was ours or external (DIAG-08), then S12.
  do_not: >
    Do not raise max_error_rate_before_abort because the contention count is
    high. The contention count is not in the rate that tripped.
  agent_instruction: >
    When summarizing, report both counts as two findings, not one. "The run
    aborted because 30% of requests returned 500s; separately, 40 contention
    events caused the guard to step down twice" is two actionable facts.
    "The run aborted under load" is neither.

DIAG-10e:
  symptom: >
    "A Puma process I don't recognise is holding my development database" /
    "port already in use after a Loadwright run" / "my next run says the database
    is already contended"
  cause: >
    An earlier :http run was killed in a way it could not clean up after — SIGKILL,
    a closed laptop lid, a power loss, a killed terminal. Loadwright boots a real
    server in :http mode and tears it down on exit and on SIGINT, but SIGKILL is
    not trappable, so the server outlives the run and keeps its database
    connections open.
  explanation: >
    This is not something the user did wrong. It is the one teardown path the gem
    cannot guarantee, which is why the recovery is automatic rather than manual.
    Each :http run writes a pidfile recording the server's PID AND process start
    time, plus the harness's, into a per-run temp directory. The next :http run
    scans for those directories and reaps any server whose harness is gone.
  fix: |
    Start another :http run — the reap happens before it boots anything, and it
    prints what it cleaned up. If the user wants it gone without a run:
      1. Find it:  ps aux | grep '[p]uma'
      2. Confirm it is Loadwright's before killing anything: its temp directory is
         named loadwright-run-*, under the system temp dir.
      3. kill <pid>   (not -9 first; it stops cleanly)
  safety_note: >
    Loadwright never kills on PID alone. A PID gets recycled, so the recorded start
    time must match too; a record written by a different HOSTNAME is left entirely
    alone (a shared TMPDIR can expose another machine's directories, where a PID
    names an unrelated process); and a server whose harness is still alive is
    treated as a concurrent run and left completely alone. Give the same advice:
    never kill a PID from a stale file without confirming it is the same process.
    This is our own child process, not a database session — see INV-11 scope_note.
  do_not: >
    Do not tell the user to delete their database, restart Postgres, or reset
    anything. One stale process is holding connections; killing that process is the
    whole fix.

DIAG-11:
  symptom: "p99 missing from report"
  cause: intentional — sample size can't support it
  fix: raise requests_per_endpoint_per_level (p99 needs several hundred)
  never: describe this as a bug or work around it by lowering
         min_samples_for_percentiles to fabricate a number

DIAG-12:
  symptom: "Concurrency findings say 'unavailable'"
  cause: execution_mode is :in_process, which has no real thread pool
  fix: re-run with --mode http
  never: interpret "unavailable" as "no problem found" (INV-08)

DIAG-13:
  symptom: "compare refuses to run"
  cause: comparability gate — runs differ on a dimension that affects measurement
  dimensions_checked: [execution_mode, scale_factors, concurrency_levels,
                       requests_per_cell, containment settings, endpoint set]
  fix: re-run one side with matching config
  correct_behavior: >
    This is the tool working. A plausible-looking meaningless delta is worse
    than no comparison.

DIAG-14:
  symptom: ":http mode — query findings all unavailable"
  cause: collector middleware not installed (remote target, or app doesn't
         load the gem)
  effect: degrades to external-only metrics (status, latency, payload size)
  fix: run against a locally-booted server, or ensure the target app loads
       the gem in its environment

DIAG-15:
  symptom: "transactional_rollback selected but data persists / errors"
  cause: :transactional_rollback is unavailable in :http mode — separate
         process can't see the harness's transaction
  fix: use :delete_created_rows, or switch to :in_process

DIAG-16:
  symptom: >
    ":http run, but the report shows no query counts / no N+1 findings /
    'no collector middleware' as the reason on every endpoint"
  cause: >
    The run got the External collector, not Middleware. That happens when
    http_target_url points at a server Loadwright did NOT boot: arming the
    collector means getting a per-run secret into the app's process, and nothing
    can do that for a process someone else started.
  do_not: >
    Do NOT report this as "no N+1 problems found". Nothing was measured. This is
    the http+external column of 5.1 and it is the single easiest place to produce
    a confidently-wrong all-clear.
  fix: |
    Let Loadwright boot the server (unset http_target_url, set
    http_server_command), or accept the reduced capability and say so explicitly
    in any summary. Response-derived signals -- payload growth, the validity
    gate, cold/warm, true client latency -- are still trustworthy.

DIAG-17:
  symptom: >
    "Two endpoints in the same report have different signals available" /
    "the capability section lists more than one window"
  cause: >
    Capability degraded mid-run: the collector middleware stopped responding, or
    under :http the app process died. Capability is recorded per WINDOW, and
    results stay attributed to the capability in effect when they were collected.
  fix: >
    Nothing to fix in the app. Read the downgrade cause in the report -- if the
    app process died, that IS the finding, and it is more important than anything
    else in the run.
  agent_instruction: >
    Findings from before and after the downgrade are not equally trustworthy.
    Never summarise such a run as one confidence level. See GAP-02, INV-13.

DIAG-18:
  symptom: >
    "loadwright run exits 3 and says no endpoints to exercise" /
    "loadwright run exits 3 immediately"
  cause: |
    Exit 3 is a REFUSAL: nothing ran. One of, in the order they are checked:
      - not run from the Rails app root (no config/environment.rb)
      - the app raised while booting -- that is the app's error, not Loadwright's
      - the safety guard declined (environment not in enabled_environments)
      - containment could not be enforced and abort_if_containment_unavailable
      - discovery produced no exercisable endpoint
  do_not: >
    Never read exit 3 as a clean run. No endpoint was measured. It is deliberately
    distinct from 0 and 1 for exactly this reason.
  fix: >
    The stderr message names which one it was. For the discovery case the usual
    causes are an empty openapi_spec_paths, no `loadwright record` recording, and
    excluded_paths filtering more than intended.
```

---

## 9. REPORT_INTERPRETATION

### 9.0 Fix suggestions

```yaml
what_they_are: >
  Some findings carry a `suggestion` alongside `detail`: the shape of a likely fix,
  derived from the normalised query. Rendered as "Try:" under the finding.
what_they_are_not: >
  A verdict. They are read off a query shape with no knowledge of the surrounding
  code, they never change an outcome state or the exit code, and a shape that is
  not recognised produces NO suggestion rather than a guess.
agent_instruction: >
  Relay a suggestion as a starting point, not as the fix. Say where it came from
  (the repeated query's shape) so the user can judge it against their own code.
  Never invent one for a finding that does not carry it.
the_one_to_get_right: >
  For a repeated COUNT the suggestion deliberately says `includes` will NOT help.
  That is correct and is the most common wrong advice about N+1s: preloading still
  counts with a query unless the code stops calling .count. Do not "improve" it
  back to "add includes".
```

### 9.1 The three states — never collapse to two

```yaml
healthy:        measured successfully, no findings
has_findings:   measured successfully, problems found
inconclusive:   COULD NOT VALIDLY MEASURE — not a pass, not a fail
inconclusive_causes:
  - response failed validity gate (bad status, schema mismatch, empty result)
  - endpoint quarantined by contention guard
  - external lock holder made attribution impossible
  - path params unresolvable
AGENT_RULE: >
  When summarizing for a user, always report the inconclusive count
  separately. "18 endpoints clean" is a lie if 12 of them were inconclusive.
```

### 9.1a State derivation — where the state comes from

```yaml
state_derivation:
  rule: >
    State is derived from finding-class COVERAGE, not from how many signals
    produced a number. A class is COVERED if at least one of its detectors was
    measurable.
  order:
    1_validity_gate: >
      Response failed the gate (bad status, schema mismatch, empty with seeded
      data, inconsistent shape) -> inconclusive for THAT reason. No coverage
      question arises.
    2_findings: any finding -> has_findings
    3_coverage: >
      A class with NO covering detector, where at least one detector was
      ATTEMPTED and failed -> inconclusive(incomplete_coverage), naming the
      class. A class whose detectors were all not_applicable does NOT escalate,
      and neither does an advisory class. See 9.1b.
    4_otherwise: healthy
  precedence_note: >
    Findings outrank a coverage gap. A concrete defect is the most actionable
    thing the tool can say, and the gap is still visible because coverage is
    reported either way.

  AN_UNMEASURABLE_SIGNAL_IS_NOT_A_FINDING: >
    It never appears in the finding count. Unavailability lives in the signal's
    Measurement (which carries the reason) and in the coverage map.

  THE_CONSEQUENCE_AGENTS_GET_WRONG: >
    Reduced coverage on an otherwise-clean endpoint is NEITHER a finding NOR
    inconclusive. An endpoint whose N+1 slope was unmeasurable but whose
    pattern-match detector ran and came back clean is HEALTHY — the N+1 class
    was covered, with one detector instead of two. Do not report it as a
    problem, and do not report it as unmeasured. Report it as healthy, and
    mention the reduced coverage if the user is weighing how much to trust the
    result.
```

### 9.1b Coverage map — read this on every endpoint

```yaml
coverage_map:
  reported: on EVERY endpoint, whatever its state
  purpose: >
    More informative than any single state label. Lets a reader see reduced
    coverage without inconclusive being overloaded to signal it.
  shape: |
    checked:     N+1 (pattern), pagination, over-fetch
    not checked: index analysis (EXPLAIN not implemented in this version),
                 latency percentiles

  classes_and_detectors:
    n_plus_one:         [pattern_match, slope]
    missing_pagination: [payload_growth]
    over_fetch:         [query_response_comparison]
    index_scan:         [explain]
    latency:            [percentiles]

  detector_states:
    available:      ran, produced a usable answer -> COVERS its class
    unavailable:    attempted, could not answer   -> a real coverage GAP
    not_applicable: never attempted               -> reported, NOT a gap

  THE_DISCRIMINATOR: >
    WHO PREVENTED THE ANSWER.

    unavailable  = the APP or its data did. We asked and could not find out.
                   Examples: no query data came back from the target; result
                   size could not be varied so the slope has one point.

    not_applicable = the RUN was never asked to look. Nothing was attempted, so
                   nothing failed. Examples: detect_overfetching = false; a
                   single scale_factors entry, so payload growth has one data
                   point; a detector whose subsystem is not in the installed
                   version (EXPLAIN, latency percentiles).

  why_three_states_and_not_two: >
    Collapsing not_applicable into unavailable would mark EVERY endpoint
    inconclusive for index analysis until ExplainAnalyzer ships, and every
    endpoint of a deliberately narrow run inconclusive for pagination. That
    makes the state meaningless during exactly the period it is most needed.

  DIFFERENT_ADVICE_PER_STATE:
    unavailable: >
      Something about the run or the target prevented a real check. This is
      worth acting on: name what would restore it (run against a locally-booted
      server so the collector middleware is installed; widen page_size_sweep or
      seed more so result size can vary).
    not_applicable: >
      Nothing went wrong. Either the user turned it off, their config cannot
      answer that question, or the version does not implement it yet. Say which.
      NEVER report this as a problem with the app, and never as a failed check.
  do_not: >
    Do not conflate the two. "We could not check X" and "you did not ask us to
    check X" lead to completely different advice, and telling a user their app
    could not be measured when they simply set scale_factors to one value is a
    fabricated problem.

  advisory_classes: [over_fetch]
  advisory_rule: >
    Over-fetch is a hint that must never fail a build (S9.2), so it must not be
    able to force inconclusive either — that is a strictly stronger statement
    than a hint. An over-fetch gap is REPORTED and does not change state, in
    either direction: an endpoint is never inconclusive because over-fetch could
    not be checked, and never healthy *because* over-fetch was skipped.
  advisory_admission: >
    A class is advisory only if its findings are inherently unfalsifiable from
    Loadwright's vantage point — correct and incorrect code produce the same
    observation. "Noisy" and "low confidence" are NOT grounds. If a user asks
    why some other noisy signal is not advisory, that is the answer.

  agent_instruction: >
    When citing a clean endpoint, cite its coverage with it. "healthy, checked
    for N+1 and pagination; index analysis not available in this version" is
    honest. Bare "healthy" overstates a partial check.
```

### 9.2 Finding types and what to tell the user

```yaml
n_plus_one_pattern_match:
  meaning: duplicate query fingerprints from the same call stack
  confidence: high
  action: includes/preload the association; check the serializer first

n_plus_one_slope:
  meaning: query count grows with returned record count
  confidence: high
  note: catches cases fingerprint matching misses
  disagreement_with_pattern_match: informative, not a bug — report both

over_fetch_hint:
  meaning: tables queried whose data never reaches the response
  confidence: LOW — hint only
  caveat: >
    Data is legitimately loaded for authorization, filtering, and derived
    values without being serialized. Present as "worth checking", never as
    a defect. Never fail anything on this.

missing_pagination:
  meaning: response payload grows linearly with seeded data
  confidence: high
  note: query count may be perfectly flat — one query can load 10k rows

slow_query_seq_scan:
  meaning: EXPLAIN found a sequential scan on a large table
  action: suggest the index; note it's a suggestion, not a verified plan

time_breakdown_view_dominant:
  meaning: majority of time in serialization, not DB
  action: >
    Redirect the user AWAY from query optimization. This is a serializer
    problem. Common in Jbuilder/AMS-heavy APIs.

pool_vs_threads_mismatch:
  meaning: Puma threads x workers > ActiveRecord pool size
  confidence: high, static check
  action: raise pool size in database.yml; latent even if unobserved

cold_warm_gap_large:
  meaning: endpoint depends heavily on caching
  action: note worst-case (post-deploy, post-flush) is much worse than avg
```

### 9.3 Mandatory caveats to include in any summary

```yaml
always_state:
  - execution mode used
  - inconclusive count, separately from healthy count
  - whether containment was active (numbers are optimistic if outbound HTTP
    was blocked / jobs suppressed)
  - sample counts behind any percentile cited
  - if :in_process: that capacity findings are unavailable, not absent
```

### 9.4 Percentile trust floors

```yaml
p50: >= 20 samples
p95: >= 100 samples
p99: >= 500 samples
below_floor: omitted by the tool; do not reconstruct or estimate them
```

---

## 10. REGRESSION_COMPARISON

```yaml
signal_hierarchy:
  tier_1_trustworthy: [query_count, allocation_count, payload_size]
    reason: near-deterministic; reproducible across machines and modes
  tier_2_noisy: [latency_p50, latency_p95, latency_p99]
    reason: laptop latency moves 10-20% between IDENTICAL runs

reporting_rule: |
  A query count going 3 -> 47 is unambiguous. Report it plainly.
  A p95 going 180ms -> 205ms is probably nothing. Report it as
  "within noise" unless it cleared BOTH regression_threshold_pct AND the
  measured noise floor.

noise_floor_procedure: |
  Run the baseline TWICE on the same commit. The delta between those two
  runs is the machine's noise floor. Without this, regression_threshold_pct
  is a guess.

state_transition_trap: |
  An endpoint moving healthy -> inconclusive has NOT improved. If its
  findings disappeared because it stopped being measurable, that is not a
  fix. Surface it as its own event.

cross_mode: |
  Comparison refuses across execution modes for latency. Query metrics may
  optionally compare, clearly labelled partial.
```

---

## 11. SAFETY_ANSWERS

Canned, accurate responses to common user safety questions.

```yaml
Q: "Can I run this in production?"
A: >
  By default, no — it refuses outside development and test. There is an
  explicit four-layer opt-in path (config flag + typed confirmation phrase +
  --i-understand-the-risk + a dry run that only --execute overrides), which
  exists for production-data-shaped staging boxes, not production. I won't
  enable it for you; that's a decision for you to make deliberately. (INV-01)
  Say "a dry run by default", never "a mandatory dry run first": nothing
  tracks whether an earlier dry run happened, and --execute is accepted in
  the same invocation. Overstating a safety control is its own failure --
  a user who believes a rehearsal is enforced will skip checking for one.

Q: "Will this delete my dev data?"
A: >
  No. Cleanup deletes only rows Loadwright itself created, tracked by ID.
  It never truncates tables. It does WRITE seed rows during a run — if your
  dev database is shared, mention that to your team first.

Q: "Will it send real emails / hit Stripe / run my jobs?"
A: >
  No, by default. Mail delivery, background jobs, and outbound HTTP are all
  suppressed, and the run aborts rather than proceeding if containment
  can't be enforced. Note this makes measured latency optimistic relative
  to production.

Q: "Can it take down my database?"
A: >
  It actively guards against that: pre-flight lock/statement timeouts, a
  baseline health check that refuses to start on an already-contended DB,
  and a five-rung retreat ladder (pause -> reduce concurrency -> quarantine
  the endpoint -> cooldown -> global abort). It never kills sessions — it
  only ever sends less work.

Q: "Is it safe to Ctrl-C?"
A: >
  Yes. SIGINT is trapped: it stops requests, tears down any booted server,
  cleans up seeded rows, and writes a partial report.

Q: "Can I point it at staging?"
A: >
  Only via explicit opt-in. A non-loopback http_target_url bypasses the
  local environment gate — the receiving process may be a different
  environment entirely — so it requires allow_remote_http_target, is
  treated as production-adjacent, and Loadwright asks the target to
  identify its own environment. I won't configure that for you. (INV-03)
```

---

## 12. CONTENTION_TUNING

```yaml
symptom_to_knob:
  "too many false quarantines / runs never finish":
    raise: latency_degradation_multiplier      # 4.0 -> 6.0
    raise: degradation_windows_before_backoff  # 3 -> 5
  "DB gets hammered before it backs off":
    lower: latency_degradation_multiplier
    lower: health_poll_interval_ms
  "run feels hung":
    lower: backoff_max_delay_ms
    lower: max_backoff_attempts
  "aborts too early on a struggling DB":
    raise: max_consecutive_quarantines
    raise: post_quarantine_cooldown_ms
  "lock timeouts on legitimately slow queries":
    raise: lock_timeout_ms
    caveat: slower to detect real contention

profiles:
  conservative: shared dev DB; prefers a useless-but-harmless run
  balanced:     default; local DB you own
  aggressive:   throwaway/containerized DB; still retreats, still never kills

backoff_math: |
  defaults: 250 + 500 + 1000 + 2000 = 3.75s per contention event
  plus 5s cooldown per quarantine
  worst case before global abort ~= 3 x 8.75s ~= 26s
  jitter adds up to 30% per delay
  RECOMPUTE THIS if backoff_max_delay_ms or max_backoff_attempts is raised.

breaker_vs_guard: |
  These own DISJOINT error classes and do not need to be balanced against
  each other:
    circuit breaker  -> "this endpoint is broken" (auth, routing, 500s)
    contention guard -> "the database is under pressure" (locks, pool, timeouts)
  Tier 1 contention exceptions are excluded from the breaker's error-rate
  numerator by classification. Both counts appear separately in report
  metadata. Do NOT advise raising max_error_rate_before_abort to stop
  contention tripping the breaker — if that is happening it is a bug.
  A breaker abort and a high contention count in the same run are two
  independent signals; read them separately (DIAG-10d).
  See DIAG-10, DIAG-10b, DIAG-10c, DIAG-10d.
```

---

## 13. CI_USAGE

```yaml
recommendation: DON'T
reason: >
  Loadwright is a local exploratory tool. It seeds data at scale, drives
  concurrent load, and takes minutes. For CI regression gating, the right
  tool is n_plus_one_control — deterministic, fast, purpose-built for
  assertions.

if_user_insists:
  minimum_config:
    execution_mode: :in_process
    scale_factors: [1, 10]
    concurrency_levels: [1]
    contention_profile: :conservative
    fail_on_n_plus_one: true      # opt-in, default false
  requirements:
    - dedicated throwaway database, never shared
    - generous job timeout (runs are minutes, not seconds)
    - artifact upload for the report
  still_tell_them: >
    n_plus_one_control will do the gating better. This is a supplement at
    best.
```

---

## 14. AGENT_ANTIPATTERNS

Things agents get wrong with this gem. Check yourself against these.

```yaml
AP-01:
  wrong: Disabling require_successful_response to "get results" from an
         all-inconclusive run.
  right: Fix auth (DIAG-01). The gate exists to prevent measuring error paths.

AP-02:
  wrong: Summarizing "20 endpoints, 18 healthy" when 12 were inconclusive.
  right: Always report inconclusive separately (INV-07).

AP-03:
  wrong: Treating "unavailable in this mode" as "no problem found".
  right: Say the finding wasn't measurable and name the mode that would
         measure it (INV-08).

AP-04:
  wrong: Reporting a 15% p95 increase as a performance regression.
  right: Check the noise floor. Lead with query-count deltas.

AP-05:
  wrong: Recommending unique_field_generator to fix a factory collision.
  right: Add a sequence to the factory. The generator is for
         resources with no factory at all.

AP-06:
  wrong: Suggesting the user kill blocking DB sessions to clear contention.
  right: Reduce load. Loadwright never kills sessions and neither should
         your advice (INV-11).

AP-07:
  wrong: Enabling allow_mutating_requests because the user asked to "test
         all endpoints".
  right: Ask explicitly. Explain what mutating load does. (INV-02)

AP-08:
  wrong: Blaming an endpoint for contention caused by an external blocker.
  right: Check whether the blocking session was ours. External = inconclusive.

AP-09:
  wrong: Optimizing queries for an endpoint whose time breakdown is 80% view.
  right: Redirect to the serializer.

AP-10:
  wrong: Presenting an over-fetch hint as a defect.
  right: Low-confidence hint; authorization queries legitimately trigger it.

AP-11:
  wrong: Raising scale_factors to 200 on the first run.
  right: Start [1, 10], confirm the pipeline works, then scale.

AP-12:
  wrong: Pasting a full report into Slack without checking redaction.
  right: Verify redaction settings first (INV-10).
```

---

## 15. PRE_RESPONSE_CHECKLIST

Before telling a user a run is set up correctly or results are ready:

```yaml
setup_checklist:
  - initializer contains `if defined?(Loadwright)`
  - gem is in development+test group only
  - auth_token_provider returns something usable
  - dry-run was reviewed before --execute
  - user consented if allow_mutating_requests is on
  - no INV-* violated

results_checklist:
  - execution mode stated
  - inconclusive count reported separately from healthy
  - containment skew disclosed if relevant
  - percentiles cited have adequate sample counts
  - any latency delta checked against noise floor
  - no over-fetch hint presented as a defect
  - findings tied to specific endpoints, not summarized into vagueness
```

---

## 16. ESCALATE_TO_HUMAN

Stop and ask rather than deciding:

```yaml
- any change to allow_production, allow_remote_http_target,
  allow_mutating_requests
- pointing at any non-loopback target
- running against a shared or unfamiliar database
- disabling any side-effect containment
- disabling the response validity gate
- results that suggest the tool itself is misbehaving (contradictory
  signals, impossible numbers) — report the gap rather than rationalizing it
- user asks for a "force" / "skip safety" / "just make it run" option
```

---

## 17. VERSION_SYNC

```yaml
this_file_describes: intended behavior of an unimplemented gem
on_conflict_with_observed_behavior: the gem wins; say this file is stale
sync_requirement: >
  Config keys here must match the generated initializer, the README, and
  Loadwright::Configuration. A spec enforces that all four agree; if you add
  a key anywhere, add it in all four places or that spec fails by design.
gem_internals_reference: .claude/skills/loadwright-development/
```

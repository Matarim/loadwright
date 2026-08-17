# CLAUDE.md — Loadwright

> **Project status: nothing has been built yet.** This repository contains
> planning documents only. There is no gem, no `lib/`, no specs, no
> `Gemfile.lock` — the first session that acts on these documents is
> starting from an empty directory. Every architecture tree, config key,
> class name, and CLI command described anywhere in this repo is a
> *target*, not a description of existing code. Do not assume any of it
> exists until you have verified it on disk.

This file is read automatically at the start of every Claude Code session in
this repo. It is the source of truth for what this project is, what it must
never do, and how work on it should proceed. If anything in a prompt
conflicts with this file, this file wins unless the user explicitly says
otherwise in that session.

> **Naming note:** `loadwright` / `Loadwright` is a placeholder name chosen
> for these planning docs. Rename freely (search-and-replace across this
> file, the skill, and the gemspec) before publishing — nothing here depends
> on the name itself.

---

## 1. What this is

Loadwright is a Ruby gem for Rails APIs that answers one question a developer
should be able to ask locally, before code ever reaches a teammate or CI:
**"If I hit every endpoint in this API with realistic, schema-valid traffic
at increasing scale, where does it fall over — and why?"**

It combines four things that normally live in separate tools:

1. **Discovery** — knows what endpoints exist and what a valid request to
   each one looks like, sourced from an OpenAPI/Swagger document *and* from
   the app's own integration/request specs.
2. **Data seeding** — uses the app's own FactoryBot factories to populate
   the database at increasing scale so query patterns that only show up
   with real data volume (N+1s, missing indexes) actually surface.
3. **Instrumentation** — watches query counts, query duplication, raw SQL
   timing, memory allocation, and connection pool pressure per request.
4. **Reporting** — turns a run into a single readable document (HTML by
   default) ranking the worst offenders by endpoint.

It is a **local developer diagnostic tool**, not a CI gate and not a
production APM. See "Non-goals" below.

## 2. The one rule that overrides all others

**Loadwright must never generate load against a production environment
unless the user has cleared every layer of the safety gate described in
`.claude/skills/loadwright-development/references/production-safety.md`.**

This is not a "best effort" requirement. Default behavior, with zero
configuration, must be: refuse to run anywhere except `development` and
`test`. Every safety-guard decision made at runtime must be logged into the
report output, so a run's provenance is always auditable after the fact.

When in doubt while implementing anything that touches environment
detection, request execution, or data mutation: **fail closed, not open.**
An aborted run that annoys a developer is an acceptable outcome. A load test
that fires real mutating traffic against production is not.

### Corollaries — the other four ways this tool could do damage

The production gate is necessary but not sufficient. Four more things can
cause real harm even when the environment check passes correctly:

1. **The initializer itself must be safe to load in production.**
   `config/initializers/loadwright.rb` is evaluated in *every* environment,
   including production, but the gem belongs in the `:development, :test`
   Gemfile group — so an unguarded initializer raises `NameError` and
   **crashes the production boot**. The generated file must wrap everything
   in `if defined?(Loadwright)`, the same way Bullet's does. There must be
   a spec for this.

2. **Cleanup must not destroy a developer's local data.** Blanket
   `TRUNCATE` of tables in a development database will wipe seed data,
   fixtures, and hand-crafted local state a developer may have spent real
   time on. Loadwright deletes only the rows it created, tracked by ID —
   never whole tables. See `references/configuration.md`.

3. **Requests have side effects beyond the database.** Hitting endpoints
   under load can send real emails, enqueue real background jobs, fire
   real webhooks, and call real third-party APIs — including from a
   developer's laptop. Side-effect containment is on by default and is its
   own subsystem, not an afterthought.

4. **The load itself can lock up the database.** Detection, backoff, and
   quarantine are covered in `references/resource-contention.md`. The rule
   there is absolute: Loadwright retreats from contention and never
   attempts to resolve it (no killing sessions, ever).

5. **A confidently wrong "all clear" is its own kind of harm.** An
   endpoint returning `403` in 4ms with one query looks perfect to a
   query-counting tool. So does one returning `[]` because the seeded
   records didn't match its scope. Reporting either as healthy tells the
   developer something false about their app. Every endpoint's response
   must prove it did the work before any performance verdict is attached
   to it — see `references/response-analysis.md`. Three outcome states,
   never two: **healthy / has findings / inconclusive.**

6. **Interruption must be clean.** `ensure` blocks don't run on signals.
   Trap SIGINT/SIGTERM explicitly: stop issuing requests, tear down any
   booted server, clean up seeded rows, write the partial report. A
   Ctrl-C that leaves 200k seeded rows and an orphaned Puma process behind
   is a bug, and it's the state a user will most often interrupt from.

7. **Estimate before you run.** Endpoints × scale factors × concurrency
   levels × requests per cell can easily reach hours. Compute and display
   the estimated duration and worst-case backoff budget *before* starting,
   with a confirmation prompt above
   `config.long_run_confirmation_threshold_minutes`. Nobody should
   discover a four-hour run by waiting through it.

## 3. Architecture at a glance

**Scaffolded, not implemented.** The tree below exists on disk; everything
except the core value objects and `Configuration` raises
`NotImplementedError`. See section 6 for what is actually built.

### The three seams (read this before touching `execution/`)

Capability is a property of the **collector**, not of the execution mode.
An `:http` run against a remote target that doesn't load the gem has the
same transport as a fully-instrumented one and dramatically less
capability — so a single fused "driver" keyed off `execution_mode` reports
confident numbers for things it never measured. Instead:

1. **`Transport`** — how a request is issued. Returns a `RawResponse`.
   Knows nothing about instrumentation.
2. **`Collector`** — how metrics come back. `Direct` (in-process),
   `Middleware` (correlated over HTTP), `External` (response-derived only).
3. **`CapabilityProfile`** — a frozen value object saying what is
   measurable and *why not* when it isn't. `CapabilityTimeline` holds the
   ordered epochs, because capability degrades mid-run (middleware stops
   responding; the app process dies) and results must stay attributed to
   the capability actually in effect when they were collected.

**Nothing under `analysis/` or `reporting/` may branch on
`config.execution_mode`.** They consult `CapabilityProfile`. A spec
enforces this; reporting may *display* the mode in run metadata with an
explicit `# capability-exempt:` marker.

```
lib/loadwright/
  measurement.rb        # tri-state: value | unavailable(reason). Never nil.
  capability_profile.rb # frozen; what is measurable and why not
  capability_timeline.rb# run-scoped epochs; the mutable half, kept separate
  endpoint_outcome.rb   # healthy / has_findings / inconclusive (+ reasons)
  configuration.rb      # the Configure DSL + provenance, see references/configuration.md
  lifecycle.rb          # ONE teardown registry; one SIGINT trap at the CLI
  safety/           # environment detection + confirmation gate (build first)
    environment_guard.rb
    remote_target_identifier.rb # Layer 1b; self-report refuses, never approves
    confirmation.rb
  discovery/
    openapi_source.rb        # parses OpenAPI/Swagger docs; fails loud on partial parse
    integration_spec_source.rb # records real requests from the app's own specs
    route_source.rb          # Rails route introspection, gap-filling only
    merger.rb                # keyed by (path_template, verb)
    path_param_resolver.rb   # seeded ids > recorded ids > overrides > example
    endpoint.rb               # normalized representation both sources produce
  seeding/
    factory_bot_seeder.rb    # scale-factor data population, see references/discovery-and-load-engine.md
    identity_pool.rb         # rotates identities; single-identity traffic lies
  instrumentation/
    query_tracker.rb         # N+1 / query count via ActiveSupport::Notifications
    memory_tracker.rb
    connection_pool_tracker.rb
    pg_stat_tracker.rb       # optional, Postgres only
  engine/
    load_runner.rb           # TWO sweeps: seed-scale and page-size, one axis fixed each
    circuit_breaker.rb       # error-rate abort; contention errors EXCLUDED
    resource_guard.rb        # lock/pool contention detection + backoff ladder
    health_poller.rb         # out-of-pool DB health sampling
  side_effects/
    containment.rb           # mail/job/HTTP suppression, see safety reference
  execution/
    raw_response.rb          # what every transport returns
    transport/               # HOW REQUESTS ARE ISSUED
      base.rb
      in_process.rb          # ActionDispatch::Integration, default mode
      http.rb                # real Puma + HTTP, see execution-modes.md
      null.rb                # scripted; backs --dry-run and fast tests
    collector/               # HOW METRICS COME BACK
      base.rb
      direct.rb              # shares the app's process; reads AS::N directly
      middleware.rb          # request-ID correlation; subscribe ONCE, route
      external.rb            # response-derived only; query signals unavailable
    collector_middleware.rb  # Rack middleware; guarded, localhost, per-run secret
    identity_endpoint.rb     # UNGUARDED, minimal; breaks the Layer 1b circularity
    server_manager.rb        # boot/health-poll/teardown; registers with Lifecycle
    execution_context.rb     # binds transport + collector + capability timeline
  analysis/
    response_validator.rb    # validity gate: status, schema, non-empty
    response_correlator.rb   # queries-per-record, over-fetch, payload growth
    serializer_attribution.rb
    time_breakdown.rb        # db / view / GC / external / other
    explain_analyzer.rb      # SELECT-only ANALYZE; see performance-signals.md
    pool_sizing_check.rb
    statistics.rb            # percentile validity, variance, noise floor
  history/
    run_store.rb             # persisted run records
    comparator.rb            # regression detection, comparability gate
    redactor.rb              # collection-time sanitizing
  reporting/
    run_result.rb            # the one structure every format renders from
    html_report.rb
    markdown_report.rb
    json_report.rb
    comparison_report.rb
  cli.rb / rake tasks
  railtie.rb                 # deliberately inert on load

lib/generators/loadwright/
  install_generator.rb
  templates/loadwright.rb.tt # authoritative config surface; drift-specced

AGENTS.md                    # agent-facing operational reference (repo root)
README.md
examples/                    # shipped example setups, see readme-and-examples.md
  minimal/ openapi_driven/ integration_spec_driven/ factory_heavy/
  paginated_api/ http_mode/ shared_dev_database/ mysql/
  large_monolith/ mutating_endpoints/ sample_app/
```

Full design detail for each subsystem lives in
`.claude/skills/loadwright-development/references/`. Read the relevant
reference file before implementing that subsystem — don't rely on memory of
this summary.

## 4. Build order (do not skip ahead)

1. **Safety guard** — environment detection, confirmation flow, circuit
   breaker. Fully tested before anything else exists.
2. **Side-effect containment** — mail, jobs, outbound HTTP.
3. **Configuration DSL** — the `Loadwright.configure` block and generator
   for `config/initializers/loadwright.rb`.
4. **Execution layer** — the `:in_process` driver first (it's the default
   and needs no orchestration), then `:http` with its correlation
   middleware. See `references/execution-modes.md`. Everything downstream
   depends on how requests are issued, so this precedes discovery.
5. **Discovery layer** — OpenAPI parsing, integration-spec recording, the
   merge logic, and path-param resolution.
6. **FactoryBot seeding** — scale-factor population, uniqueness handling,
   identity pool.
7. **Instrumentation** — query, memory, connection pool, pg_stat, time
   breakdown, GC.
8. **Resource guard** — contention detection and the backoff/quarantine
   ladder (`references/resource-contention.md`). This comes *before* the
   load engine, not after: the engine is the thing that generates
   concurrent load, and it must not exist in a form that can generate load
   without a working guard around it.
9. **Load engine** — the scale × concurrency matrix, the N+1-by-slope
   heuristic, the circuit breaker and resource guard wired in.
10. **Response analysis** — the validity gate and correlation signals
    (`references/response-analysis.md`). Query data without response data
    produces confidently wrong verdicts; this is not optional polish.
11. **Performance signals** — time breakdown, EXPLAIN/index analysis, cold
    vs warm, pool sizing, statistical validity
    (`references/performance-signals.md`).
12. **Run history & comparison** (`references/run-comparison.md`),
    including collection-time redaction.
13. **Reporting** — HTML first (it's the primary deliverable), then
    Markdown/JSON, then the comparison report.
14. **README, `AGENTS.md`, and example setups**
    (`references/readme-and-examples.md`).
    `examples/sample_app/` should be built earlier than this — the gem's
    own end-to-end tests need it — but the full example set and README
    land here.

Each subsystem should be reasonably usable and tested on its own before
moving to the next — this is a case where "vertical slice, thin but real"
beats "build every layer's skeleton at once."

## 5. Working conventions

- **TDD by default.** Every subsystem in the build order above gets specs
  before or alongside implementation, especially the safety guard.
- **Run `rake mutation_audit` after touching anything safety-critical.** A green
  suite does not mean the safety behaviours are still enforced — 22 of the
  guard's examples once passed vacuously. The audit breaks each behaviour and
  confirms its spec goes red, against a throwaway copy of the repo. See
  `tools/MUTATION_AUDIT.md`.
- **Run `rake spec:seeds`, not just `rspec`, before calling anything done.**
  `examples/sample_app` boots a real Rails app and ActiveRecord into the
  suite's own process, so any example whose premise is "Rails is not loaded"
  passes or fails depending on order. This is not theoretical: it silently
  disabled 22 of the safety guard's examples — including every "refuses to
  run in production" case — because the guard read `::Rails.env` and ignored
  the injected environment. State such premises with `hide_const` or an
  injected collaborator; never rely on load order.
- **Small, reviewable commits.** One subsystem/behavior per commit; don't
  bundle unrelated changes.
- **No silent guessing on safety behavior.** If a design choice in
  `production-safety.md` is ambiguous for a specific edge case, stop and
  ask rather than picking the more permissive interpretation.
- **Config over code.** If a reasonable person might want to turn a
  behavior on/off, it should be a config key (see
  `references/configuration.md`), not a hardcoded constant.
- **Update this file as you go.** Section 6 (status) should reflect
  reality at the end of every session, not the plan from day one.
- **Keep `AGENTS.md` current.** It's the operational reference agents will
  act on when helping users adopt this gem, and a stale agent doc is worse
  than a stale human one — an agent acts on it confidently without the
  skepticism a human reader applies. Any change to config keys, CLI
  commands, report states, or failure modes updates `AGENTS.md` in the same
  commit. A drift spec enforces the config-key half of this.

## 6. Status

**Current state: the gem is feature-complete for v1 and drivable end to end.**

`bundle exec loadwright run --execute` boots a host Rails app, clears the safety
gate, installs containment, discovers endpoints, seeds, runs the matrix, analyses
the results, writes HTML/Markdown/JSON, and persists a redacted run record --
against `examples/sample_app`, in both transports, from the real binary.

What is left is judgement rather than construction: the six triage items at the
end of this section, and a decision about publishing.

`bundle exec rake spec:seeds` is green at 1386 examples across 5 seeds
(1 pending: a GC-time example skipped on Rubies that do not report it). The
self-arming README drift check is now ARMED and passing -- the README documents
all 93 config keys, and removing one turns the suite red.
`bundle exec rake mutation_audit` is green at 28/28.

Update this section at the end of each work session — it is how the next
session knows where things actually stand, and it is the only place in this
repo that should ever describe *current* state rather than intended state.

**Built and specced:**

- [x] Gem skeleton — gemspec, Gemfile, Rakefile, `.rspec`, LICENSE, exe
- [x] `Measurement` — tri-state, never nullable, no numeric coercion
- [x] `CapabilityProfile` — frozen; derived from (transport, collector)
- [x] `CapabilityTimeline` — run-scoped epochs; mid-run degradation
- [x] `EndpointOutcome` — three states, enumerated inconclusive reasons
- [x] `Configuration` — 92 keys, provenance, presets as data, lazy Rails
      defaults, resolved-value comparability fingerprint, `validate!`
- [x] Generated initializer template (full 92-key surface)
- [x] Documentation-drift spec — initializer ↔ Configuration equality,
      AGENTS.md ⊆ Configuration, README self-arming
- [x] Architecture spec — no `config.execution_mode` in analysis/reporting
- [x] CLI argument parsing and `--help`/`--version`
- [x] `examples/` structure (11 placeholder READMEs)
- [x] README stub pointing at CLAUDE.md

- [x] `Lifecycle` — teardown registry, one SIGINT/SIGTERM trap, self-pipe
      watcher so the handler itself never takes a mutex
- [x] Safety guard — Layers 1, 1b, 2, 3, 4; identity endpoint; asymmetric
      trust; no generic `confirmation_phrase` fallback
- [x] `CircuitBreaker` — error-rate abort with contention structurally
      excluded from the numerator
- [x] Side-effect containment — mail/jobs/outbound HTTP, abort-if-
      unenforceable, restoration registered with `Lifecycle`
- [x] `loadwright:install` generator — writes the initializer, adds
      `tmp/loadwright/` to `.gitignore` idempotently, pre-fills the
      discovery section from what it finds on disk. Specced against a real
      generated file, not the template.

- [x] Execution layer, all three seams — `Request`, `RawResponse`,
      `RequestMetrics`; `Null`/`InProcess`/`Http` transports;
      `Direct`/`Middleware`/`External` collectors; `CollectorMiddleware`;
      `ServerManager`; `ExecutionContext` (owns mid-run epoch transitions)
- [x] `QueryTracker` — ONE global subscriber, routed by request id in
      `IsolatedExecutionState`. Unattributed queries counted, not dropped.
      No-bleed proven under real concurrent HTTP.
- [x] `Railtie` — identity endpoint mounted unconditionally; collector
      middleware inserted dormant at boot, armed only by `mount!`

- [x] Discovery layer — `Endpoint` (merge key = `(template, verb)`),
      `SchemaRef`, `OpenapiSource` (fails loud on partial parse),
      `RouteRecognizer`, `IntegrationSpecSource` (records, never parses),
      `RouteSource` (gap-filling), `Merger`, `PathParamResolver`
- [x] `History::Redactor` — collection-time, honours the host's
      `filter_parameters`
- [x] `examples/sample_app/` — live fixture: unpaginated N+1, PAGINATED N+1
      (the Part 2 regression fixture), over-fetch, 403, one clean endpoint,
      and a factory deliberately missing a `sequence`
- [x] `FactoryBotSeeder` — batched, id-tracked cleanup (never TRUNCATE),
      collision reported not worked around, adopts rows a failed batch
      committed
- [x] `IdentityPool` — deterministic rotation; single-token warning

- [x] Instrumentation — `CurrentRequest` (one shared request-id read),
      `QueryTracker`, and `Analysis::TimeBreakdown`, all WIRED.
      `MemoryTracker`, `ConnectionPoolTracker` and `PgStatTracker` are built and
      specced but **instantiated by nothing in a run** — so no allocation figure,
      pool sample or pg_stat row reaches any report. `CapabilityProfile` now says
      so outright rather than advertising them (see triage item 1),
- [x] Resource guard — `HealthPoller` (dedicated out-of-pool connection,
      Postgres/MySQL/generic probes, ours-vs-external via application_name),
      `ResourceGuard` (pre-flight timeouts, baseline gate, three tiers,
      five-rung ladder, both carve-outs, printable backoff budget)
- [x] Load engine — `LoadRunner`: two sweeps with one axis fixed each,
      concurrency-1 baselines after the first seed, breaker + guard wired in,
      dry-run matrix printing, duration + backoff estimate
- [x] Response analysis — `ResponseValidator` (validity gate),
      `ResponseCorrelator` (returned-record slope, payload growth, over-fetch
      hints), `SerializerAttribution`
- [x] `Coverage` + coverage-derived outcome state — three detector states,
      advisory classes, per-class coverage reported on every endpoint
- [x] `Reporting::RunResult` — the one structure every format renders from,
      incl. `sweeps.seed_scale.observed_page_size` for the comparability gate
- [x] End-to-end gate — one real run per transport against `sample_app`,
      asserting on FINDINGS. Booted once per transport, not per example.

- [x] `Analysis::Statistics` — percentiles omitted (never caveated) when the
      sample cannot support them, per CELL not per endpoint, budget checked at
      the highest supported percentile with the substitution disclosed; sample
      counts, coefficient of variation, and the noise-floor arithmetic
- [x] `Analysis::ExplainAnalyzer` — SELECT-only ANALYZE behind a whitelist,
      Postgres/MySQL/SQLite, run after the load phase on its own connection.
      Mutation-audited: a write statement is never executed
- [x] `Analysis::PoolSizingCheck` — two Measurements from one check; the static
      half works under `:in_process`, the observed half does not. Compares
      threads > pool PER PROCESS, not threads x workers
- [x] `Analysis::ColdWarm` — the warmup pass kept rather than discarded; the
      application cache is cleared only when it is process-local
- [x] `Analysis::ContainmentDisclosure` — the required skew statement, on run
      metadata and on every endpoint's breakdown
- [x] `Analysis::TrafficDiagnosis` — rate limiting and auth misconfiguration
      diagnosed at the RUN level, re-labelling endpoints `:rate_limited` /
      `:auth_failed`
- [x] `Analysis::TimeBreakdown` WIRED — Direct subscribes in-process; under
      `:http` the railtie arms an app-side one and the collection endpoint
      carries the timings back. Per-endpoint db/view/gc/other
- [x] Job fan-out finding — a per-request DELTA, unavailable when requests
      overlapped rather than misattributed
- [x] `History::Redactor` reach — `Measurement` reasons and capability
      downgrade causes; one `#document` pass over the whole record
- [x] `History::RunStore` — redacted on the way in, Lifecycle-armed so an
      interrupted run still leaves a record, bounded by `run_history_limit`,
      baseline pointer with a measured noise floor
- [x] `History::Comparator` — the three-part comparability gate, query counts
      as the primary signal, latency gated on threshold AND noise floor,
      state transitions that must not read as fixes
- [x] CLI `runs list` / `baseline set` / `compare` (exit 2 = not comparable)

- [x] Reporting — `HtmlReport`, `MarkdownReport`, `JsonReport` through a shared
      `Presenter`; capability per window with each downgrade's cause; the three
      states visually distinct, inconclusive sorted above healthy; an aborted run
      marked partial above the fold
- [x] `ComparisonReport` — Markdown and HTML; a refusal renders nothing else;
      state changes before "Resolved" so an endpoint that became unmeasurable is
      not read as a fix
- [x] Full `examples/` set — ten initializers plus READMEs, each evaluated by
      `examples_spec.rb` the way a host app does
- [x] `Discovery::Pipeline` — the three sources and the merge as one call, so
      `--dry-run` and `--execute` cannot discover different endpoint sets
- [x] CLI `run` and `record` — `AppLoader` boots the host app; the pipeline is
      assembled in the order the safety model requires; `--dry-run` writes no
      report; the interrupt handoff gives the partial report one writer
- [x] Run provenance in the report — the safety decision, the containment
      measures, and what discovery found. `RunResult` always accepted these;
      nothing passed them, so `metadata[:safety]` was nil in every report the
      gem could produce
- [x] README — safety before installation, a quickstart built from real captured
      output, all 93 config keys, the three-state model, and an honest
      "when not to use this"
- [x] `AGENTS.md` verified end to end — §5.1 rekeyed by transport+collector
      (the degraded `http + external` column was previously reported as fully
      capable), `INV-12` (Measurement is tri-state, never zero), `INV-13`
      (capability comes from metadata, never from `execution_mode`), `DIAG-16/17/18`,
      real exit codes. `STATUS: SPECIFICATION_ONLY` removed.
- [x] `History::Comparator` denominator gating — a query delta whose cell's record
      count also moved carries NEITHER verdict, and renders in its own report
      section above anything that reads as good news; a drop in returned records is
      itself a regression. `SIGNAL_REQUIREMENTS` is now total and explicit, and
      raises for a metric with no entry
- [x] Documentation-drift, both halves armed — README ↔ Configuration equality is
      live, and `capability_profile_spec` now checks §5.1's VALUES against
      `CapabilityProfile`, not just its row names

### Still rough — triage before calling this publishable

Nothing here blocks a run. Each is a real gap, listed so the next session
decides rather than rediscovers.

1. **Three instrumentation subsystems are built and wired to nothing.**
   `MemoryTracker`, `ConnectionPoolTracker` and `PgStatTracker` are referenced only
   by their own `require` and their own specs. Until this session the capability
   profile advertised memory and pool as available under `:http`, which put a claim
   in every report that no number in it supported; they are now honestly
   unavailable. Wiring them is NOT a quick fix: under `:http` the app is a separate
   process, so both figures have to come back over the collection endpoint the way
   `Analysis::TimeBreakdown` already does. Deleting the two assignments in
   `CapabilityProfile.derive` turns the AGENTS.md matrix spec red until §5.1 is
   corrected, which is intended.

2. **`resolved_findings` vs `changed_findings`** is unspecced for the three-way
   case: a finding whose kind persists but whose detail changes lands only in
   "changed". Believed right, untested.
3. **Mutating endpoints confounding their own measurement** is documented and
   disclosed but not *detected*. `performance-signals.md` Part 6 wants either
   per-cell state reset or an explicit confound flag.
4. **The sample app's `other` bucket is ~90% of request time.** Honest for a
   fixture this trivial, but it means the time breakdown's interesting case — an
   endpoint dominated by serialisation — has no live fixture.
5. **Three `ServerManager` specs are CPU-load-sensitive and can fail spuriously.**
   `server_manager_spec.rb:65`, `:106` and `:126` boot a real child process and
   need it healthy inside `http_boot_timeout = 1`. On a busy machine one second
   is not enough, and all three go red together — observed for real this session
   by running `rake spec:seeds` and `rake mutation_audit` at the same time. Both
   pass in isolation and in a sequential run. Not an order dependency and not a
   product bug, but it WILL bite on a loaded CI runner, and the failure looks
   alarming (teardown/SIGKILL) rather than like the timeout it is. Either raise
   that timeout or make the check wait on the child rather than the clock. Until
   then: do not run the two rake tasks concurrently.

6. **The long-run confirmation proceeds on a non-TTY** rather than refusing.
   Deliberate and commented (it is a courtesy about someone's afternoon, not a
   safety decision about irreversible harm — unlike the production gate, which
   refuses when it cannot prompt), but it is the one place a prompt is skipped
   and worth a second opinion.

### Design decisions made during M0 that the reference docs now carry

Recorded here so a later session doesn't re-litigate them from the older
prose:

1. **Three seams, not one driver** (§3 above). Capability belongs to the
   collector.
2. **Split identity endpoint, asymmetric trust** — `production-safety.md`
   Layer 1b. A target's self-report can refuse a run, never approve one.
3. **Two sweeps, one axis fixed each** — `response-analysis.md` Part 2.
4. **Contention errors excluded from the circuit breaker**, with
   repeat-offender and concurrency-1 pool-exhaustion carve-outs —
   `resource-contention.md` Part 6.
5. **Rails >= 7.0 floor**, for `ActiveSupport::IsolatedExecutionState`.
   No 6.1 fallback.
6. **`json_schemer`** over `json-schema`, for JSON Schema 2020-12
   (OpenAPI 3.1's dialect).
7. **No generic `confirmation_phrase` fallback** — unresolvable refuses the
   production path rather than substituting a guessable phrase.
8. **openapi3_parser is a 3.0 parser**, verified rather than assumed: it
   accepts a `3.1.0` version string but rejects `webhooks`, type arrays, and
   numeric `exclusiveMaximum`. It validates the document; the RAW parsed hash
   carries the schemas, because `Node::Schema#to_h` is shallow and injects
   `additionalProperties: false` — which would reject valid responses.
9. **`EnvironmentGuard` takes an injectable `rails_env`.** Without it,
   environment detection is untestable in any process where Rails is loaded,
   which is every real host app.
10. **The seed-scale sweep sends no page-size parameter at all**, so the
    endpoint is measured as clients call it. The page-size sweep runs at
    concurrency 1, because queries-per-returned-record is a single-request
    property and varying both would make the slope unattributable.
11. **`:http` writes a per-run 0700 directory** holding the collector secret
    (mode 0600, run-id bound) and a pidfile (server + harness identity, each
    PID plus process start time). Every `:http` run reaps orphaned servers
    before booting, because SIGKILL is untrappable and a leftover Puma holds
    the developer's database. Never kills on PID alone, and never kills a
    server whose harness is alive. Only the secret's PATH is in the child's
    environment.
12. **Outcome state is derived from finding-class coverage**, not signal count.
    An unmeasurable signal is never a finding. Three detector states, because
    `not_applicable` (unshipped subsystem, or disabled by config) must not
    read as a coverage gap. Over-fetch is advisory and never escalates to
    `inconclusive` — a hint may not veto a clean verdict.
13. **`openapi3_parser` pinned `< 0.11`**, with a contract spec, because the
    schema path depends on non-public API (`Validation::Error#context` and the
    raw parsed hash shape).

### Design decisions made during M1 (signals and comparison)

14. **The latency budget is checked at the highest SUPPORTED percentile**, with
    the substitution disclosed. `p95_latency_budget_ms` names p95, and the
    default 25 requests per cell cannot support p95 — refusing to check
    anything would make the latency class permanently unanswerable at default
    settings, which is the coverage flooding the three-state model exists to
    prevent. A median above the p95 budget is a *stronger* finding than the one
    asked for; the converse is stated rather than implied.
15. **`EXPLAIN ANALYZE` on a write is prevented by a whitelist, not a
    blacklist**, and the rolled-back-transaction path `performance-signals.md`
    permits is deliberately NOT implemented — it assumes no effects outside the
    transaction, which is false for sequences, advisory locks and commit-time
    triggers. Mutation-audited.
16. **SQLite is a supported EXPLAIN adapter** via `EXPLAIN QUERY PLAN`, not an
    "other adapter". `SCAN` vs `SEARCH … USING INDEX` is the core signal; the
    row threshold is applied by counting the table, which the plan omits.
17. **One exemplar SQL statement per fingerprint crosses the collection
    endpoint** under `:http`. A fingerprint cannot be explained, and
    substituting a literal changes the plan the planner picks. It is captured
    only when EXPLAIN is enabled, stripped from every serialisation, and
    dropped by the redactor. The alternative was index analysis being
    unavailable in `:http` mode, turning every endpoint inconclusive there.
18. **Pool sizing compares threads > pool PER PROCESS**, not
    `threads × workers`. Each Puma worker has its own pool; multiplying would
    invent a finding for every clustered Puma. `performance-signals.md` is
    corrected.
19. **The cold pass clears only a process-local cache.** `Rails.cache.clear`
    against Redis or Memcached wipes a cache other processes are using. An
    uncleared pass is still reported, labelled a first-request figure rather
    than a cold one.
20. **Job and mail counts are per-request deltas, and unavailable when requests
    overlapped.** The `:test` adapters are process-global and accumulate all
    run; a wrong attribution is worse than an absent one for a finding people
    act on. Overlap is DETECTED, not inferred from configured concurrency.
21. **Rate limiting and auth misconfiguration are diagnosed at the RUN level**
    and re-label endpoints with reasons that name the fix. The pattern is only
    visible across endpoints: one 403 is an admin endpoint, every endpoint
    returning 403 is a token.
22. **The comparability gate has three parts** — resolved config values, the
    app's own observed default page size, and the capability intersection.
    Config and page-size divergence refuse; a capability gap excludes the
    affected metric and names it.
23. **`compare` exits 2 when the runs are not comparable**, distinct from 1
    (regressions found). Treating "could not compare" as a pass is the silent
    failure the gate exists to prevent.

### Design decisions made during M2 (the CLI, docs, and adoption)

24. **The CLI boots the host app itself**, by loading `config/environment.rb`
    from the working directory. `loadwright` is a standalone binary, not a Rails
    command, so nothing else has loaded the app — and the guard's environment
    detection reads `Rails.env`, which does not exist until it is. Boot is
    therefore the first thing `run` does, before the safety guard.
25. **`--dry-run` writes no report and no history record.** It issues zero
    requests, so every endpoint in such a report is `inconclusive` and every
    measurement absent — a document indistinguishable from a real run that found
    an API-wide problem, sitting there as the newest report in the directory.
    Matches what `LoadRunner` already did for history.
26. **The interrupt handoff: the signal watcher waits for the main thread**,
    bounded by `FINISH_GRACE_SECONDS`. `exit_on_signal: false` alone produced
    TWO reports and had both threads inside one runner's `assemble_result` at
    once. One writer, and teardown cannot race the analysis describing what
    teardown is about to delete.
27. **Exit codes distinguish REFUSED (3) from findings (1).** Conflating them
    lets a safety refusal read as a clean bill of health. `inconclusive` never
    fails the exit code — it is a coverage gap, not a defect, and failing on it
    would make the first unauthenticated endpoint in a suite fail every run
    forever, which trains people to ignore the code entirely.
28. **Discovery warnings key off `explicitly_set?`, not off the value.** Both
    path settings have lazy defaults pointing at conventional locations, so
    warning on the value made every app without a `swagger/` directory print two
    warnings about sources it never asked for, on every run.
29. **The sample app's initializer is env-gated** (`SAMPLE_APP_LOADWRIGHT_CONFIG`).
    Everything else boots that app into the SUITE's own process and builds its
    own `Configuration`; an unconditional block would mutate the global for every
    later example, order-dependently — the `spec:seeds` hazard exactly.
30. **AGENTS.md §5.1 is keyed by transport+collector, and its VALUES are
    spec-checked.** The old matrix was keyed by mode and claimed
    `explain_index_analysis` and `connection_pool_exhaustion` were available
    under `:http` — false for a remote target. The name-level check passed
    throughout. Names drifting is cosmetic; values drifting is a wrong answer.

31. **A query count is never compared without its denominator.** `records` was
    persisted by every cell, listed in `SIGNAL_REQUIREMENTS`, and compared by
    nothing — so narrowing a scope or lowering a page-size cap made queries fall
    and the report said "No regressions". Verified against two real runs before
    and after the fix. A moved record count strips the verdict off the query delta
    (`:unattributable`, shown with its reason) and a *drop* in records is a
    regression in its own right. The run-level observed-page-size gate does not
    cover this: it samples only the largest scale factor's seed-scale cells.
32. **`SIGNAL_REQUIREMENTS` has no `nil` and no default.** `nil` meant both "needs
    no capability" and "nobody decided yet", which is exactly how `records` sat
    there uncompared for a milestone. Every compared metric now names a capability
    or `NO_CAPABILITY_REQUIRED`, and comparing a metric with no entry raises.
33. **Allocations are not compared, and nothing may claim they are.** They are not
    persisted per cell, so `clean_memory_attribution` gates nothing — recorded in
    `UNCOMPARED_SIGNALS` rather than left as an unexplained absence. The
    cross-machine warning used to promise "allocation deltas" that did not exist.

## 7. Non-goals (v1)

- Not a replacement for `n_plus_one_control` / CI regression gating —
  Loadwright is exploratory and local; it can *inform* what you turn into a
  CI assertion, but it isn't one itself.
- Not a replacement for a real APM (Scout, AppSignal, etc.) — it has no
  concept of real production traffic.
- Not a high-concurrency capacity-planning tool like k6/vegeta/wrk — the
  concurrency levels it drives are meant to be enough to surface N+1s, pool
  pressure, and memory bloat locally, not to model production scale.

## 7b. Deferred — worth building, deliberately not in v1

These are real gaps, not oversights. They're deferred because each needs
design work that would delay a usable v1, and each is additive rather than
structural.

- **GraphQL: complexity-aware load shaping.** Everything else is BUILT --
  operation-level discovery, execution, the read-vs-mutation distinction,
  the 200-with-errors validity gate, connection page-size sweeping, and
  per-resolver attribution via `Instrumentation::GraphqlTracer`, which a
  host schema opts into with `trace_with`. What remains is shaping load by
  query complexity rather than by request count, so an expensive query and
  a trivial one are not driven at the same rate.
- **Multiple databases / read replicas.** Rails 6+ `connected_to` and
  horizontal sharding mean more than one pool; current pool tracking
  assumes one. Would also enable a genuinely useful finding: queries hitting
  the primary that should have gone to a replica.
- **Resumable runs**, for suites long enough that an interruption is
  costly.
- **Long-run trend visualization** beyond pairwise comparison.

If a session picks any of these up, treat it as a new subsystem with its
own reference doc rather than bolting it onto an existing one.

## 8. Where to go next

Start every substantial work session by reading, in order:

1. This file.
2. `.claude/skills/loadwright-development/SKILL.md`
3. Whichever `references/*.md` file covers the subsystem you're touching.
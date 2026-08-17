---
name: loadwright-development
description: Use this skill whenever building, extending, debugging, or reviewing any part of the Loadwright gem itself — the safety guard, the configuration DSL, the OpenAPI or integration-spec discovery layer, FactoryBot-based data seeding, query/memory/connection-pool instrumentation, the scaled load-testing engine, or report generation. Trigger this for any work under lib/loadwright/**, the initializer template, or the gem's own spec suite, even if the request doesn't mention "Loadwright" by name — e.g. "add a config option for X", "the N+1 detector isn't catching Y", "make the report include Z" should all trigger this skill.
---

# Loadwright Development

This skill captures the design decisions for Loadwright so they don't have
to be re-derived (or accidentally re-litigated) every session. Read
`CLAUDE.md` first for the one-paragraph pitch and the non-negotiable safety
rule — this file is the working manual for building each subsystem.

## Core design principles

1. **Safety-first, always.** Every other principle below is subordinate to
   this one. See `references/production-safety.md` before touching
   environment detection, request execution, or anything that could mutate
   data.
2. **Config over code.** New behavior should default to something safe and
   be exposed as a config key on `Loadwright.configure`, not hardcoded. See
   `references/configuration.md` for the full key list and where to add to
   it.
3. **Reuse instrumentation patterns, don't reinvent them.** The query/N+1
   tracking should hook `ActiveSupport::Notifications` on
   `sql.active_record` the same way Bullet and Prosopite do — don't build a
   parallel SQL-parsing layer. Where an existing gem's approach is directly
   applicable, borrow the technique and cite it in a code comment rather
   than silently reproducing it.
4. **Fail loud, not silent.** A seeding collision, a parse failure on the
   OpenAPI doc, an endpoint that can't be authenticated — all of these
   should show up clearly in the terminal and in the report, never get
   swallowed.
5. **Deterministic, reproducible runs.** Given the same config, factories,
   and OpenAPI doc, two runs should produce comparable results. Log the
   git SHA, config snapshot, and random seed used for data generation into
   every report.

## Subsystems and where their detail lives

| Subsystem | Reference file | One-line summary |
|---|---|---|
| Environment detection & confirmation gate | `references/production-safety.md` | Multi-layer guard; default-deny outside dev/test |
| Side-effect containment (mail/jobs/HTTP) | `references/production-safety.md` | On by default; abort if unenforceable |
| Contention detection & backoff ladder | `references/resource-contention.md` | Retreat, never resolve; quarantine and move on |
| `Loadwright.configure` DSL + generator | `references/configuration.md` | Exhaustive, grouped config keys with safe defaults |
| Endpoint discovery (OpenAPI + integration specs) | `references/discovery-and-load-engine.md` | Two sources merged into one `Endpoint` list |
| FactoryBot seeding at scale | `references/discovery-and-load-engine.md` | Scale-factor population, uniqueness handling |
| Load engine (scale × concurrency matrix, N+1-by-slope) | `references/discovery-and-load-engine.md` | The "smart" part — see that file's heuristic section |
| Instrumentation (query, memory, pool, pg_stat) | `references/discovery-and-load-engine.md` | Hooks feeding the report, keyed by endpoint |
| Execution modes (`:in_process` / `:http`) | `references/execution-modes.md` | Determines what's measurable; correlation machinery for HTTP |
| Response validity gate & correlation | `references/response-analysis.md` | Three outcome states; no verdict without response proof |
| Signals beyond query counts | `references/performance-signals.md` | Time breakdown, EXPLAIN, cold/warm, pool sizing, statistics |
| Run history & regression comparison | `references/run-comparison.md` | Query deltas are signal; latency deltas are mostly noise |
| Reporting (HTML/Markdown/JSON) | `references/reporting.md` | What each report section must contain, plus redaction |
| README & shipped examples | `references/readme-and-examples.md` | Adoption is a feature; safety documented before install |
| `AGENTS.md` agent reference | `references/readme-and-examples.md` | Root-level, machine-oriented; invariants over prose |

## Recommended build order

Follow `CLAUDE.md` section 4. Don't parallelize subsystems out of order —
the load engine depends on seeding and instrumentation existing and being
trustworthy first; the report depends on the load engine producing
structured data, not the reverse.

## Definition of done, per subsystem

Before considering any subsystem complete, it should have:

- [ ] Unit specs covering the happy path and at least one failure mode
- [ ] Every new behavior exposed as a documented config key (or an explicit
      note in the PR/commit for why it isn't configurable)
- [ ] For anything touching request execution or environment detection: a
      spec that proves it refuses to run under a simulated production
      environment
- [ ] An entry added to `CLAUDE.md` section 6 (Status)
- [ ] No new external network calls beyond hitting the local app under test
      (no telemetry phone-home, no version-check pings, unless the user
      asks for that explicitly)

## Common pitfalls to actively guard against

- **Treating "not Rails.env.production?" as sufficient.** It isn't — see
  `production-safety.md` for why hostname/ENV heuristics matter too.
- **Parsing arbitrary RSpec files with a hand-rolled AST walker** for the
  integration-spec discovery source. This is fragile and will silently miss
  valid requests. The recommended approach is *recording*, not *parsing* —
  see `references/discovery-and-load-engine.md`.
- **Auto-generating "unique" values to route around FactoryBot uniqueness
  collisions.** Don't. Surface the collision as an actionable error telling
  the user which factory/field needs a `sequence`. Silently working around
  it produces data that doesn't match how the app is actually used.
- **Conflating query *count* with query *cost*.** A flat query count across
  scale factors doesn't mean the endpoint is fast — a single unindexed
  query can dominate. Both signals belong in the report; don't let one
  substitute for the other.
- **Writing an initializer without the `if defined?(Loadwright)` guard.**
  Rails loads initializers in every environment; the gem is dev/test-only.
  Omitting the guard crashes production boots. Spec it.

- **Truncating tables during cleanup.** That destroys a developer's local
  data. Delete only rows Loadwright created, tracked by ID.

- **Forgetting that requests have non-database side effects.** Load-testing
  a `POST` can send real email, enqueue real jobs, and call real
  third-party APIs from someone's laptop. Containment is on by default.

- **Trying to "fix" database contention.** Never terminate, cancel, or
  kill sessions. Back off, quarantine, move on. See
  `references/resource-contention.md`.

- **Blaming an endpoint for an externally-held lock.** If the blocking
  session isn't one of ours, the result is `inconclusive`, not a finding.

- **Attaching a performance verdict to a response that failed.** A `403`
  or `[]` response with one fast query is not a healthy endpoint. Gate
  every verdict on response validity — `inconclusive` is a required third
  state, not an edge case.

- **Measuring N+1 slope against seeded count on a paginated endpoint.**
  Pagination hides the N+1 completely from seed-based slope. Measure
  against *returned* record count and sweep page-size params. See
  `references/response-analysis.md` Part 2.

- **Reporting over-fetch as a hard finding.** Data gets loaded for
  authorization and filtering without being serialized all the time.
  Hints only; never a build failure.

- **Letting `http_target_url` bypass the environment gate.** A remote
  target means the local `Rails.env` describes the wrong process entirely.
  Treat non-loopback targets as production-adjacent and make the target
  identify itself. See `production-safety.md` Layer 1b.

- **Reporting concurrency findings from `:in_process` mode.** There is no
  real thread pool there. Mark them unavailable; don't fabricate them.

- **Leaving ActiveRecord's query cache on during a run.** It dedupes
  identical queries within a request and can hide a textbook N+1
  completely.

- **Sending placeholder path params.** OpenAPI example IDs 404 against a
  freshly-seeded database. Resolve from seeded records, or skip the
  endpoint and say why.

- **`EXPLAIN ANALYZE` on a write statement.** It *executes* the statement.
  ANALYZE is SELECT-only; everything else gets plain EXPLAIN.

- **Reporting p99 from 25 samples.** Omit percentiles the sample size
  can't support rather than printing noise with a decimal point.

- **Comparing runs with different configs or execution modes.** Refuse and
  say which dimension diverged — a plausible-looking meaningless delta is
  worse than no comparison.

- **Treating a latency delta as a regression.** Laptop latency moves
  10–20% between identical runs. Query counts are the trustworthy signal.

- **Writing unredacted SQL and response bodies to `tmp/`.** Redact at
  collection time, not render time, so secrets never reach the persisted
  run record either.

- **Letting `AGENTS.md` drift from the implementation.** Agents act on it
  confidently without the skepticism a human reader would apply, so a stale
  agent doc produces confidently wrong advice to users. Update it in the
  same commit as any config/CLI/report-state change.

- **"Cleaning up" `AGENTS.md` into readable prose.** Its density and
  lookup-table structure are the point — they remove the inference step
  that makes agents apply operational rules inconsistently.

- **Assuming a report format is "done" without opening it in a browser.**
  The HTML report is the primary deliverable a developer will actually
  look at; generate a real sample run's worth of data and eyeball it before
  calling that subsystem finished.

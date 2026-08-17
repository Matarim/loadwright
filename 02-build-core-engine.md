Continuing work on Loadwright. Before starting, re-read CLAUDE.md
(especially section 6 — it is the only place describing what actually
exists; everything else describes what's intended) and
`.claude/skills/loadwright-development/SKILL.md` plus its references. Don't
rely on memory of the last session.

M0 is done, so this session starts from a different place than the original
plan assumed. Already built and real: `Measurement` (tri-state),
`CapabilityProfile` (versioned/degradable), `EndpointOutcome`,
`Configuration` (with explicit-assignment tracking and provenance), and the
`Lifecycle` teardown registry. Everything else is a stub raising
`NotImplementedError`.

Carry these decisions from last session forward — they override anything in
the reference docs that wasn't updated:

- **Three seams, not fused drivers**: Transport (issue request → RawResponse)
  / MetricsCollector (request id → RequestMetrics) / CapabilityProfile
  (which signals are available and why not). Capability is a property of the
  *collector*, not the mode.
- **Nothing under `analysis/` or `reporting/` may reference
  `config.execution_mode`.** They consult `CapabilityProfile`. One annotated
  exception for the report metadata header's display read.
- **`Measurement` is never nullable.** `Measurement.unavailable(reason)`, not
  `nil`.
- **One SIGINT trap**, at the CLI, via the `Lifecycle` registry. Server
  manager and seeder register teardown callbacks into it; neither traps
  signals itself.
- **Rails floor is `>= 7.0`**, correlation uses
  `ActiveSupport::IsolatedExecutionState`.
- **`json_schemer`** for schema validation.

Work through the subsystems in order, treating each as done (per SKILL.md's
"definition of done") before the next.

---

1. **Safety guard** (`references/production-safety.md`). The most important
   code in the gem. All four layers — environment allowlist, heuristic
   detection, explicit production opt-in, dry-run default — plus **Layer 1b**
   (remote targets) with the split-endpoint design:

   - **Identity endpoint**: mounted whenever the gem is loaded, no secret,
     returns only `{env:, loadwright_version:, enabled_here:}`. No SQL, no
     stack traces, no bind values.
   - **Asymmetric trust**: a remote target's self-report is authoritative
     for *refusal* and never for *approval*. Reports a disallowed
     environment → hard refuse. Reports `development` → grants nothing,
     every other Layer 3 condition still applies. Unreachable or won't
     identify → refuse.
   - **`confirmation_phrase`**: if it can't resolve from the Rails app and
     the run is taking the production-adjacent path, refuse and tell the
     human to set it explicitly. No generic fallback string — that defeats
     the point of an app-specific phrase.

   Work the doc's full "Testing requirements" list, including the specs
   proving each of the four opt-in conditions is independently required and
   the six Layer 1b remote-target cases. Do not proceed until they all pass.

2. **Side-effect containment** (`references/production-safety.md`,
   containment section) — mail, background jobs, outbound HTTP. Include the
   abort-if-unenforceable path, and register the restore-original-settings
   teardown with `Lifecycle` rather than relying on `ensure` alone.

3. **Configuration: finish the parts M0 deferred.** `Configuration` itself
   exists — don't rebuild it. What's left:

   - The three `contention_profile` presets as data, applied only to
     untouched keys, resolved once at run start, order-independent.
   - The `loadwright:install` generator actually writing the full template
     from `references/configuration.md` (comments included) into a real
     app's `config/initializers/loadwright.rb`. Spec that the generated file
     contains `if defined?(Loadwright)` — omitting it breaks production
     boots.
   - The drift spec, three-way active now (initializer ↔ `Configuration` ↔
     `AGENTS.md`), with the directional rules: equality for the first two,
     **subset only** for `AGENTS.md` (every key it mentions must exist; the
     reverse doesn't hold). README joins in session 4 via a
     self-deactivating skip, not a `pending` example.

4. **Execution layer** (`references/execution-modes.md`, as amended by the
   three-seam design). Build in this order:

   - `NullTransport` + a scripted collector first. This is what makes the
     entire downstream pipeline testable without booting Rails or opening
     sockets — build it before the real transports so you're not tempted to
     test through Puma.
   - `InProcessTransport` — the default.
   - `HttpTransport` + `ServerManager` (boot, health poll, teardown
     registered with `Lifecycle`).
   - `MetricsCollector` implementations: `Direct`, `Middleware`, `External`
     (the null/degraded case).

   The correlation implementation matters more than the transport. Per last
   session's finding: **subscribe once globally at run start, not
   per-request.** `ActiveSupport::Notifications` subscribers are
   process-global, so a per-request subscriber fires for every thread's SQL
   and you attribute other requests' queries to whoever is listening. Route
   each event to a bucket via a current-request-id in
   `IsolatedExecutionState`, set by the middleware. Test with deliberately
   overlapping concurrent requests and assert no metric bleed.

   Document the known residual gap rather than being silently wrong about
   it: queries from `load_async` or app-spawned threads run in a different
   fiber and will under-attribute. That goes in `AGENTS.md` as a known gap,
   not just a code comment.

   `CapabilityProfile` must record **mid-run downgrades** — timestamped,
   with cause, and every request attributed to the profile in effect when it
   ran. A middleware that stops responding, or an app process that dies,
   degrades collection silently otherwise.

5. **Discovery layer.** OpenAPI source first, against a small fixture doc.
   Two things from last session:

   - If an OpenAPI document can't be fully parsed — 3.1 documents are the
     likely case given `openapi3_parser`'s 3.0 focus — **fail loudly at
     discovery.** Never produce a partial endpoint list: endpoints that were
     never tested would be reported as absent rather than skipped, which
     tells someone their API is clean when half of it was never looked at.
     Confirm the 3.1 situation now rather than assuming either way.
   - Integration-spec recording: the hard part is path templates, not
     interception. The recorder observes `/api/v1/posts/42`, but the merge
     key is `(path_template, verb)` — reverse-map through
     `Rails.application.routes.recognize_path` to recover the pattern before
     anything can merge with OpenAPI. Capture the concrete IDs alongside the
     template; they're resolution order #2 for path params.

   Then merge/de-dupe, then path-param resolution from seeded records.
   Follow "recording, not parsing" literally — if you find yourself walking
   RSpec ASTs, stop and reread that section.

6. **FactoryBot seeding** — against `sample_app`, with at least one factory
   deliberately missing a `sequence` so the collision-reporting path is
   tested rather than silently worked around. Batch the inserts.
   `:delete_created_rows` tracks inserted IDs — no `TRUNCATE` ever.
   Register cleanup with `Lifecycle`. Note that
   `:transactional_rollback` is unavailable under `HttpTransport` and must
   be caught at startup with a clear message.

7. **Instrumentation** — query/N+1 via the global subscriber from step 4,
   memory, connection pool, pg_stat_statements (degrading gracefully off
   Postgres), and the db/view/GC time breakdown (`process_action` already
   carries `db_runtime` and `view_runtime`, so this is cheap and it's what
   stops the report blaming the database for a serialization problem).
   Disable ActiveRecord's query cache during runs — it dedupes identical
   queries within a request and hides textbook N+1s.

8. **Resource guard** (`references/resource-contention.md`) — pre-flight
   timeouts, baseline health check, three detection tiers, five-rung ladder
   (pause → step down → quarantine → cooldown → global abort). Before the
   load engine, per CLAUDE.md's hard ordering.

   Implement the **structural breaker/guard split** decided last session:
   Tier 1 exception classes are contention events, routed to the guard and
   **excluded from the circuit breaker's error-rate numerator**. Both counts
   reported separately in metadata. Two carve-outs where a contention error
   *is* an endpoint finding and must not vanish into "the database was under
   pressure":

   - **Repeat offender**: blocker was ours, same endpoint across multiple
     cells → report as an endpoint finding, not only guard telemetry.
   - **Pool exhaustion at concurrency 1**: `ConnectionTimeoutError` under
     real concurrency is load pressure; the same error at concurrency 1 is
     almost certainly an application connection leak. Different diagnosis —
     classify on concurrency level rather than routing all
     `ConnectionTimeoutError` uniformly.

   Full testing requirements including the spec proving Loadwright never
   issues a terminate/cancel/kill statement under any contention scenario.
   Have the CLI print the computed worst-case backoff budget at run start.

9. **Load engine.** The matrix shape is now an explicit decision, not
   emergent — **two separate sweeps, one axis held fixed each:**

   - Seed-scale sweep, page size fixed → does query *cost* grow with table
     size? (index/scan behavior)
   - Page-size sweep, seed scale fixed high enough to fill several pages →
     does query *count* grow with records returned? (the N+1)

   Never vary both in one sweep; you can't attribute the slope if you do.
   Measure the concurrency-1 baseline per endpoint before ramping (the
   guard's Tier 3 check depends on it). Record the concurrency each cell
   *actually* ran at, which may be lower after a step-down. Wire both the
   breaker and the guard to intervene mid-run in a test.

10. **Response analysis** (`references/response-analysis.md`). Validity gate
    first — status, schema validity via `json_schemer`, empty-response-with-
    seeded-data, cross-scale shape consistency — then the correlation
    signals (queries per returned record, over-fetch hints, payload growth,
    serializer attribution).

    Every signal reads capability from `CapabilityProfile` and emits
    `Measurement`, so an unavailable signal is `unavailable(reason)` rather
    than absent or zero. The three outcome states must be distinct through
    the data model via `EndpointOutcome`, not assembled at the reporting
    layer.

    Required regression test: a fixture endpoint that is paginated *and*
    has an N+1, proving the returned-record-count slope catches what the
    seeded-count slope misses. That test is the reason the subsystem exists.

---

**`examples/sample_app/`** gets built as soon as you need something real —
probably at step 5 or 6. One N+1, one unpaginated endpoint, one
over-fetching endpoint, one that 403s, so every analysis path has a live
fixture rather than a mock.

**Required gate before this session is done:** at least one real end-to-end
run per transport against `sample_app`. `NullTransport` plus a scripted
collector is fast-test infrastructure, and fast-test infrastructure drifts
from reality precisely because it's convenient.

Specs alongside implementation, commits scoped per subsystem, CLAUDE.md
section 6 updated as each lands. Any doc edits from this session's
decisions go in the same commit as the code. If a reference doc doesn't
answer a design question, stop and ask rather than picking the more
permissive or convenient option — especially anywhere near the safety
guard.

Don't start reporting, the README, or the full examples set — next session.
I want to see the engine and response analysis producing real structured
output against `sample_app` first, so we can check the data shape before
building report templates around it.

At the end: summarize what's implemented, what the suite covers, and
anything you deviated from the docs on with your reasoning.

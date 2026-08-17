# Performance Signals Beyond Query Counting — Design Reference

> **Status: specification for software that does not exist yet.** Nothing
> described in this document has been built. Every statement here defines
> *intended* behavior, not current behavior — read it as a build order, not
> as documentation of a working system. When implementation diverges from
> this document, update the document in the same commit.


Query counts are where this tool started, but an endpoint's time goes to
many places. This document covers the signals that make the difference
between "12 queries, 340ms" and an actually actionable diagnosis.

---

## Part 1 — Where the time actually went

Rails APIs commonly spend 40% or more of a response in serialization, and
a report that attributes all 340ms to "the database" sends the developer
to optimize the wrong layer.

`process_action.action_controller` gives `db_runtime` and `view_runtime`
essentially for free. Combined with total duration, that yields a
breakdown per endpoint:

- **Database** — `db_runtime`
- **View/serialization** — `view_runtime` (Jbuilder, AMS, Blueprinter,
  `as_json`)
- **GC** — from `GC.stat` deltas around the request; report both time and
  whether a major GC occurred
- **External HTTP** — time in outbound calls, when not blocked by
  containment
- **Everything else** — total minus the above; large values here usually
  mean middleware or application-layer computation

Render this as a stacked breakdown, not a single number. An endpoint at
340ms with 280ms in serialization is a serializer problem, and no amount
of query optimization will help it.

### Containment skews this, and the report must say so

`suppress_background_jobs` and `block_outbound_http` make the app faster
than production reality — jobs aren't performed, third-party calls return
instantly. That's the correct default, but the time breakdown must
disclose it: "external HTTP blocked; real-world latency will be higher."
Reporting a containment-inflated number as though it were the truth is the
same category of error as reporting a 403 as fast.

Also report **jobs enqueued per request**, above
`config.jobs_enqueued_warning_threshold` (default 10 — not zero, since
enqueuing a job from a `POST` is ordinary). A request enqueuing 200 jobs is
a finding in its own right, and containment is what makes it visible.

It has to be a **delta over the request**, not the total the `:test` adapter
has accumulated: the raw total grows monotonically across a run, so
reporting it per request shows request 500 enqueuing 500 jobs and request 1
enqueuing one — a number that rises with nothing but time. And because the
adapters are process-global, a delta is only attributable when no other
request was in flight; **overlap is detected rather than inferred from the
configured concurrency**, and an overlapping request reports the count
unavailable rather than crediting one request with another's jobs.

---

## Part 2 — EXPLAIN and index analysis

We identified missing indexes as a core problem category from the start.
Query counting will never surface them — loading 10,000 rows via a
sequential scan is *one* query.

After the load phase completes (never during it — this would skew timing),
take the slowest distinct queries per endpoint and run `EXPLAIN` on a
separate connection.

### The safety rule that matters here

**`EXPLAIN ANALYZE` executes the statement.** Running it on an
`INSERT`/`UPDATE`/`DELETE` performs the write. Therefore:

- `EXPLAIN (ANALYZE, BUFFERS)` is used **only on `SELECT` statements.**
- Any non-`SELECT` gets plain `EXPLAIN` (plan only, no execution).

  **The rolled-back-transaction path is deliberately not implemented.** It
  depends on the statement having no effects outside the transaction, which
  is false for sequences, advisory locks, commit-time triggers, and anything
  reached through a foreign data wrapper — and the failure mode is a real
  write to a real table. This document's own tiebreak settles it: when in
  doubt plain `EXPLAIN` wins, and here there is always doubt.

- Eligibility is decided by a **whitelist, not a blacklist**: read-shaped
  leading keyword, AND no data-modifying keyword anywhere (so a
  `WITH … (DELETE … RETURNING *)` CTE is caught), AND a single statement,
  AND no side-effecting function call. Anything unclassifiable is treated as
  a write.
- EXPLAIN runs under the same `lock_timeout_ms` / `statement_timeout_ms`
  as everything else.

### What to detect and report

- Sequential scans on tables above `config.seq_scan_row_threshold`
- Sorts spilling to disk (external merge)
- Nested loops over large row counts
- Rows-returned vs rows-examined ratios indicating poor selectivity
- Estimated vs actual row divergence, which usually means stale statistics

Each finding pairs with the endpoint that caused the query and, where
possible, a concrete suggestion (which column an index would cover).
Postgres gets the full treatment; MySQL gets `EXPLAIN FORMAT=JSON` with
fewer signals; **SQLite gets `EXPLAIN QUERY PLAN`**, which reports `SCAN`
versus `SEARCH … USING INDEX` — fewer signals again (no row counts, no
timings, so the row threshold is applied by counting the table), but it is
the signal that matters most, so SQLite is supported rather than dropped
into "not available". Other adapters degrade to "not available," stated
plainly.

Two states that look alike and must not be conflated: **"we looked at this
endpoint's queries and none was slow enough to explain"** is a clean answer
covering the index-scan class, while **"we never saw its queries"** (an
external collector) is a coverage gap. Both arrive as an empty candidate
list, so the caller passes which one it is.

A fingerprint cannot be explained — `WHERE id = ?` is not runnable, and
substituting a literal changes the plan the planner picks, which is the
thing being measured. So one **exemplar statement** per fingerprint is kept,
captured only when EXPLAIN is enabled, stripped from every serialisation,
and never persisted.

---

## Part 3 — Cold vs warm cache

The current plan discards warmup requests. That throws away the
interesting case: **cold-cache performance is exactly what users hit right
after a deploy, a cache flush, or a restart.**

With `config.measure_cold_cache` (default `true`), report both:

- **Cold** — the first requests, currently discarded as warmup
- **Warm** — steady state after warmup
- **The delta**, which is the actionable number

A large cold/warm gap means the endpoint depends heavily on caching, and
its worst case is far worse than its average. That's worth knowing before
a deploy, not after.

Note honestly what can and cannot be reset between passes: Rails caches
can be cleared, but the database buffer cache and OS page cache generally
can't be from inside the tool. Label the cold measurement as
"application-cache cold," not "fully cold," rather than overclaiming.

**And only clear a cache that is ours to clear.** `Rails.cache.clear`
against Redis or Memcached wipes a cache other processes are using —
possibly a colleague's, on a shared development instance. That is the tool
damaging the environment it was pointed at, which is the category of harm
the whole safety design exists to prevent. Only provably process-local
stores (`MemoryStore`, `NullStore`) are cleared; everything else —
including any store not on that list, since guessing wrong destroys
someone's data — is left alone, and the result is then labelled a
**first-request** figure rather than a cold one.

---

## Part 4 — Connection pool vs server thread sizing

The classic Rails production incident: Puma `max_threads` exceeds the
ActiveRecord pool size, so threads queue for connections under load and
latency collapses in a way that looks like a slow database but isn't.

Loadwright is well positioned to catch this and should check it explicitly:

- Read the ActiveRecord pool size and, in `:http` mode, the server's
  configured thread/worker counts.
- Flag more server threads than pool connections as a configuration finding
  **even if no contention was observed during the run** — it's a latent
  problem, and stating it costs nothing.

  **Correction, made during implementation.** The comparison is `threads >
  pool_size` **per process**, not `threads × workers > pool_size`. Each Puma
  worker is a separate process with its own ActiveRecord pool, so `-w 4
  --threads 1:4` against a pool of 5 is correctly configured — multiplying
  would invent a finding for every clustered Puma in existence. The worker
  count is still reported, because it changes the total connections the
  *database* sees, but that is a `max_connections` concern and a different
  finding from this one.
- Report pool `waiting` counts and the high-water mark of `busy` vs
  `size` observed during the run.

In `:in_process` mode this check is limited to the static config
comparison; the observed-contention half is unavailable and must be
labelled as such.

---

## Part 5 — Statistical validity

The plan reports p50/p95/p99 from a default of 25 requests per cell. A p99
computed from 25 samples is noise wearing a decimal point.

- Establish minimum sample counts per percentile: p50 needs relatively
  few; p95 needs roughly 100+; p99 needs several hundred to mean anything.
- Statistics are computed **per cell**, not per endpoint. A cell holds one
  scale factor, one page size, and one concurrency level, so its latencies
  are draws from one distribution; pooling concurrency 1 with concurrency 20
  produces a median describing neither.
- **The budget is checked against the highest *supported* percentile**, and
  the report names which one it used. `p95_latency_budget_ms` names p95, and
  the default 25 requests per cell cannot support p95 — so refusing to check
  anything would make the latency class permanently unanswerable at default
  settings, which is exactly the coverage flooding the three-state model
  exists to prevent. A median above the p95 budget is a *stronger* finding
  than the one asked for; the converse does not hold, and the caveat says so
  outright.
- **Percentiles the sample size can't support are not reported.** Not
  reported with a caveat — omitted, replaced by "insufficient samples for
  p99 (need ~N, have 25)." Same principle as everywhere else in this tool.
- Report the sample count alongside every percentile.
- Report the coefficient of variation, so a reader can see when a mean is
  being dragged around by outliers.
- Prefer reporting min/median/max plus sample count for small runs over
  fabricating high percentiles.

`config.min_samples_for_percentiles` makes the thresholds adjustable, and
raising `requests_per_endpoint_per_level` is the documented fix.

---

## Part 6 — Traffic realism

### Multiple identities

Every request authenticating as the same user produces identical cache
keys, identical tenant scoping, and row-lock contention on one user's
records that wouldn't occur in production. Support an **identity pool**:
`config.auth_token_provider` may return a collection, or
`config.test_identity_pool_size` (default 5) seeds multiple users/tenants
and rotates across them.

This matters especially for multi-tenant apps, where single-tenant traffic
can make a badly-scoped query look fine because there's only one tenant's
data to filter.

### Rate limiting will throttle us

Any app running Rack::Attack or similar will start returning `429` under
load. The response validity gate correctly marks those `inconclusive`, but
the tool should go further and **detect the pattern** — a cluster of 429s,
or `Retry-After` / `RateLimit-*` headers — and tell the user plainly:
"rate limiting is throttling this run; allowlist Loadwright's requests or
disable it for this environment." Otherwise the user stares at a report
full of `inconclusive` with no idea why.

Similarly, uniform `401`/`403` across every endpoint almost always means
`auth_token_provider` isn't configured correctly, not that the entire API
is broken. Detect and say so — it will be the single most common first-run
failure.

### Mutating endpoints confound their own measurement

Firing `POST /orders` 500 times means request #500 runs against a table
with 499 more rows than request #1, so latency drift reflects data growth
rather than concurrency. Either reset state per cell, or disclose the
confound in the report. Never present the raw trend as a concurrency
finding.

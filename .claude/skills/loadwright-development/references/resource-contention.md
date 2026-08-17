# Resource Contention & Adaptive Backoff — Design Reference

> **Status: specification for software that does not exist yet.** Nothing
> described in this document has been built. Every statement here defines
> *intended* behavior, not current behavior — read it as a build order, not
> as documentation of a working system. When implementation diverges from
> this document, update the document in the same commit.


Loadwright deliberately generates concurrent load against a real database.
That means it *will* eventually cause lock contention, pool exhaustion, or
statement timeouts — not as a bug, but as a normal consequence of the job
it does. The difference between a useful tool and a destructive one is
entirely in how it responds when that happens.

**Governing principle: Loadwright observes contention and retreats from
it. It never tries to resolve contention.** Never call
`pg_terminate_backend`, `pg_cancel_backend`, `KILL <thread_id>`, or any
equivalent. Never `unlock tables`. If the database is struggling, the
correct action is always to send it *less* work, never to intervene in
what it's already doing. Any suggestion in a future session that
Loadwright "clean up" blocking sessions should be rejected on sight.

This subsystem must exist and be tested **before** the load engine starts
issuing concurrent requests (see build order in `CLAUDE.md`).

## Part 0 — Fail fast rather than hang (pre-flight)

Before any load begins, set conservative timeouts on the connections
Loadwright's own requests use, so a blocked query surfaces as a catchable
error in seconds instead of hanging the run:

- Postgres: `SET lock_timeout`, `SET statement_timeout`,
  `SET idle_in_transaction_session_timeout`
- MySQL: `SET SESSION innodb_lock_wait_timeout`, `SET SESSION max_execution_time`

Driven by `config.lock_timeout_ms` and `config.statement_timeout_ms`.
A run where every request hangs for 30s because the default lock timeout
is effectively infinite is both useless and dangerous.

## Part 1 — Baseline health check (before the run)

Poll database health once before any seeding or requests, and record it in
the report. Two purposes:

1. **Establish "normal"** so degradation is measured against this app's
   actual baseline, not an arbitrary constant.
2. **Detect pre-existing contention.** If there's already a long-running
   transaction, a migration in flight, ungranted locks, or a saturated
   connection pool *before* Loadwright does anything, abort with a clear
   message. Running a load test into an already-sick database produces
   garbage data and risks tipping over something a developer cares about.
   `config.abort_on_unhealthy_baseline` (default `true`).

## Part 2 — Detection signals

Detection is tiered because no single signal is reliable on its own.

### Tier 1 — Exceptions raised on the request path (definitive)

Catch and classify, per request:

- `ActiveRecord::LockWaitTimeout`
- `ActiveRecord::Deadlocked`
- `ActiveRecord::StatementTimeout`
- `ActiveRecord::QueryCanceled`
- `ActiveRecord::ConnectionTimeoutError` (pool exhaustion)
- `ActiveRecord::StatementInvalid` wrapping any of the above

These are unambiguous contention signals. One is a data point; a cluster
within a short window triggers the response ladder immediately — don't
wait for a statistical signal to agree.

### Tier 2 — Sampled database health poll (background thread)

Every `config.health_poll_interval_ms`, on a **dedicated connection
outside the pool under test** (critical — polling through the same
saturated pool means the health check is the first thing to fail, and you
lose visibility exactly when you need it most):

- **Postgres:** count sessions in `pg_stat_activity` with
  `wait_event_type = 'Lock'`; count ungranted rows in `pg_locks`; get the
  age of the longest-running transaction; get `xact_start` of the oldest
  idle-in-transaction session.
- **MySQL:** `sys.innodb_lock_waits` (or
  `performance_schema.data_lock_waits` on 8.0+) for waiting/blocking
  pairs; `information_schema.innodb_trx` for long transactions. Do **not**
  poll `SHOW ENGINE INNODB STATUS` on an interval — it's far too heavy and
  becomes part of the problem.
- **Any adapter:** `ActiveRecord::Base.connection_pool.stat` — the
  `waiting` and `busy` vs `size` ratio is adapter-agnostic and catches
  pool exhaustion even where lock introspection isn't available.

If the adapter isn't Postgres or MySQL, degrade gracefully to the
pool-stat signal plus Tier 1 and Tier 3, and say so plainly in the report
rather than silently running with less protection than the user expects.

### Tier 3 — Latency degradation (statistical)

Track a rolling p95 per endpoint. Compare against that endpoint's own
baseline measured at concurrency level 1. If p95 exceeds
`config.latency_degradation_multiplier` × baseline for
`config.degradation_windows_before_backoff` consecutive windows, treat it
as contention even with no exception raised and no lock visible — this
catches contention that manifests as queuing rather than as errors.

### Distinguishing our contention from someone else's

This matters more than it might seem. When Tier 2 finds a lock wait,
check whether the *blocking* session belongs to one of Loadwright's own
connections (track the backend PIDs / connection IDs Loadwright holds at
startup).

- **Blocker is ours** → genuine finding about the endpoint under test.
  Attribute it to that endpoint in the report.
- **Blocker is external** (another developer, a Sidekiq worker, a running
  migration) → back off exactly the same way, but mark the result
  **inconclusive**, not a finding. Reporting "this endpoint has a lock
  problem" when a migration was running in another terminal is a false
  positive that destroys trust in the tool.

## Part 3 — The response ladder

Progressive retreat, never a binary stop. Each rung is tried before the
next.

**Rung 1 — Pause and drain.** Stop issuing new requests. Let in-flight
requests finish. Wait `config.backoff_initial_delay_ms`, growing
exponentially by `config.backoff_multiplier` with jitter (jitter matters —
synchronized retries create their own thundering herd), capped at
`config.backoff_max_delay_ms`. Re-poll health. If recovered, resume at the
same concurrency level.

**Rung 2 — Step down concurrency.** If health doesn't recover after
`config.max_backoff_attempts` at Rung 1, drop to the next lower
concurrency level and re-run the current cell. Record that the cell was
completed at reduced concurrency — the report must never present a
stepped-down result as though it ran at the requested level.

**Rung 3 — Abandon the endpoint.** If contention persists at the lowest
concurrency level, stop testing this endpoint entirely, mark it
`quarantined` with the reason and the evidence (which signal fired, lock
details, whether the blocker was ours), and move to the next endpoint.
This is the behavior you asked for: don't grind, move on.

**Rung 4 — Cooldown before the next endpoint.** After any quarantine,
wait `config.post_quarantine_cooldown_ms` and re-run the health check
before starting the next endpoint. Starting the next test into a database
that hasn't recovered just produces a cascade of false quarantines and
keeps the pressure on.

**Rung 5 — Global abort.** If `config.max_consecutive_quarantines` is hit,
or the post-cooldown health check fails `config.max_health_check_retries`
times, abort the entire run. At that point the database is not recovering
and continuing is doing harm, not gathering data. Write a partial report
with everything collected so far — an aborted run must still produce
output, never nothing.

## Part 4 — Contention during seeding, not just requests

`create_list(:post, 200)` can itself lock tables, exhaust the pool, or
time out — especially with callbacks, counter caches, or search-index
hooks firing per record. The seeder must run under the same guard:

- Batch inserts (`config.seed_batch_size`) with a health check between
  batches rather than one giant transaction.
- On contention during seeding: back off, then retry the batch; if it
  still fails, skip that resource at that scale factor and report it,
  rather than aborting the whole run.
- Seed cleanup must **also** run under a lock timeout — a cleanup that
  hangs forever holding locks is worse than the test that preceded it. And
  cleanup must run in an `ensure` block so it happens even on global
  abort.

## Part 5 — Everything is reported

Every backoff, step-down, quarantine, and abort goes into the report (see
`reporting.md`), with: which signal fired, the evidence, whether the
blocker was ours or external, what rung was reached, and what the
resulting data means. A quarantined endpoint is **not** the same as a
clean endpoint and must never be presented as one — "we couldn't safely
measure this" is a distinct outcome from "this is fine."

## Part 6 — Tuning: what each knob does and how it changes behavior

Every threshold in this subsystem is configurable, and every default is a
starting point rather than a recommendation for all apps. This section
exists so someone tuning these values understands what they're trading
away — the failure modes at both extremes are real and neither is obvious.

### The knobs

| Key | Default | Lower it → | Raise it → |
|---|---|---|---|
| `lock_timeout_ms` | 3000 | Queries abandon locks sooner; more Tier-1 signals, less waiting, but legitimately slow-but-fine queries get misreported as contention | Slower detection; a genuinely blocked run wastes more wall-clock before reacting |
| `statement_timeout_ms` | 10000 | Long queries get cut off — useful on a shared DB, but you lose the measurement of the very query you wanted to profile | Slow endpoints are measured fully, at the cost of longer runs |
| `health_poll_interval_ms` | 500 | Faster contention detection; more polling overhead on an already-stressed DB | Cheaper, but contention persists longer before the ladder engages |
| `latency_degradation_multiplier` | 4.0 | Backs off on mild slowdowns → premature quarantines, endpoints reported `inconclusive` that were actually fine, runs that never finish | Only reacts to severe degradation → more real pressure on the DB before retreating |
| `degradation_windows_before_backoff` | 3 | Twitchier; single slow windows trigger retreat | More tolerant of noise, slower to react to genuine sustained degradation |
| `backoff_initial_delay_ms` | 250 | Retries sooner — may re-enter contention immediately | Gives the DB more room, at the cost of run duration |
| `backoff_multiplier` | 2.0 | Flatter escalation; more total retries before the cap | Reaches the delay cap faster; fewer, longer pauses |
| `backoff_max_delay_ms` | 15000 | Caps total wait — retreat is bounded but may be insufficient | More patience for slow-recovering databases |
| `max_backoff_attempts` | 4 | Steps down concurrency sooner | Tries harder at the current level before reducing load |
| `post_quarantine_cooldown_ms` | 5000 | Next endpoint starts sooner — risks cascading false quarantines into a DB that hasn't recovered | Cleaner separation between endpoints, longer runs |
| `max_consecutive_quarantines` | 3 | Aborts the run earlier when things go badly | Pushes on through a struggling database — rarely what you want |

### Worst-case time cost, so backoff can't silently eat your afternoon

The ladder's time cost is bounded and computable. With defaults, a single
contention event costs:

```
250 + 500 + 1000 + 2000 = 3.75s   (4 attempts, multiplier 2.0, under the 15s cap)
```

plus `post_quarantine_cooldown_ms` (5s) if it escalates to quarantine.
Worst case before global abort: `max_consecutive_quarantines` × (backoff
series + cooldown) ≈ 3 × 8.75s ≈ 26s of pure waiting. Jitter adds up to
`backoff_jitter` (30%) on top of each delay.

If you raise `backoff_max_delay_ms` or `max_backoff_attempts`
substantially, recompute this — it's easy to configure a run that appears
hung when it's actually just being patient. Loadwright should print the
computed worst-case backoff budget at run start so this is never a
surprise.

### The circuit breaker and this guard own disjoint error classes

`max_error_rate_before_abort` (the circuit breaker) and the contention
thresholds are **separate mechanisms handling separate failures**:

- **Circuit breaker** → "this endpoint is broken." Wrong auth, missing
  route, 500s. Correct response: abort the run, nothing useful is being
  measured.
- **Contention guard** → "the database is under pressure." Correct
  response: retreat per-endpoint via the ladder, keep the run alive.

Contention naturally *produces* errors — lock timeouts, pool timeouts,
statement timeouts. Counting those toward the breaker's error rate makes
the two mechanisms fight: the breaker aborts runs the guard was handling
correctly.

**This is resolved structurally, not by tuning.** The Tier 1 exception
classes in Part 2 are classified as contention events, routed to this
guard, and **excluded from the circuit breaker's error-rate numerator.**
Both counts are recorded separately in report metadata, so a run remains
auditable and neither mechanism hides the other's activity.

An earlier draft of this document treated the interaction as something the
operator should tune around by raising `max_error_rate_before_abort`. That
was a manual workaround for something the code can classify correctly, and
it is no longer the guidance.

#### Two carve-outs — when contention *is* an endpoint finding

Routing all contention to the guard must not let a genuine endpoint defect
disappear into "the database was under pressure." Two cases route back as
findings attributed to the endpoint:

1. **Repeat offender.** If the ours-vs-external check says the blocking
   session was *ours*, and the *same endpoint* triggers contention
   repeatedly across cells, that is a finding about the endpoint — it takes
   locks it shouldn't, or holds them too long. Report it as an endpoint
   finding alongside the contention event, not only as guard telemetry.

2. **Pool exhaustion at concurrency 1.** `ConnectionTimeoutError` under
   real concurrency is load pressure and belongs to the guard. The same
   error at concurrency level 1 is almost certainly an application
   **connection leak** — the endpoint checking out a connection it never
   returns. Very different diagnosis, and the concurrency level is what
   distinguishes them. Classify on that, rather than routing every
   `ConnectionTimeoutError` to the guard uniformly.

Everything else in the Tier 1 list routes to the guard.

**Operator note:** you may still want to raise
`max_error_rate_before_abort` for an endpoint set that legitimately returns
errors (a fuzzing-shaped suite, say). But you should no longer need to
raise it to stop contention from tripping the breaker — if you observe
that, it's a bug in the classification, not a tuning problem.

### Recommended profiles

Ship these as documented presets (see `readme-and-examples.md`):

- **`:conservative`** — for shared development databases where other people
  are working. Low concurrency, tight timeouts, twitchy degradation
  detection, long cooldowns. Prefers a useless-but-harmless run over any
  disruption.
- **`:balanced`** — the documented defaults above. Assumes a local database
  the developer owns.
- **`:aggressive`** — for a throwaway/containerized database where the only
  goal is finding problems fast and nothing is lost if it falls over. Still
  retreats; still never kills sessions.



- A spec per Tier 1 exception class proving it's caught, classified, and
  triggers the ladder rather than crashing the run.
- A spec proving the health poller uses a connection outside the pool
  under test (assert on the connection object, not on output).
- A spec simulating sustained contention that proves the ladder escalates
  in order — pause → step down → quarantine → cooldown → next endpoint —
  rather than jumping straight to abort.
- A spec proving an externally-held lock produces an `inconclusive`
  result, not a finding attributed to the endpoint.
- A spec proving a global abort still writes a partial report and still
  runs seed cleanup.
- A spec proving Loadwright never issues a terminate/cancel/kill statement
  under any contention scenario — assert on the SQL actually executed, so
  a future well-meaning change can't quietly introduce one.
- A spec per Tier 1 exception class proving it is excluded from the circuit
  breaker's error-rate numerator: a run generating contention errors well
  above `max_error_rate_before_abort` must not trip the breaker.
- A spec proving the repeat-offender carve-out fires — the same endpoint
  blocking on our own sessions across multiple cells produces an endpoint
  finding, not only a guard event.
- A spec proving `ConnectionTimeoutError` at concurrency 1 is reported as a
  suspected connection leak attributed to the endpoint, while the same
  error at higher concurrency routes to the guard as load pressure.

## Part 7 — What changes between execution modes

The guard's *policy* is identical in both modes; its *plumbing* is not.

**`:in_process`** — Loadwright and the app share a connection pool, so the
health poller's "dedicated connection outside the pool under test"
requirement means a connection Loadwright opens explicitly for polling and
keeps out of the shared pool. Tier 1 exceptions surface directly on the
request path and need no transport. Because concurrency is capped at 1
here, most pool-pressure contention simply won't occur — which is correct,
not a gap, and the report must say so rather than implying the app is
clean.

**`:http`** — Tier 1 exceptions are raised inside the app process, not
Loadwright's, so they travel back through the collector middleware. The
guard must also handle a failure mode `:in_process` can't produce: the app
process dying or hanging entirely. Add a target-liveness check to the
health poll — an unresponsive server is a Rung 5 global abort, not
something to keep issuing requests into. The health poller connects to the
database directly from Loadwright's process, so it stays genuinely
out-of-pool with respect to the app's pool.

**Both modes** — the backoff ladder, quarantine, cooldown, and the absolute
rule against killing sessions are unchanged. Every contention finding
records which mode produced it, because "no contention observed" means
substantially less in `:in_process` mode and a reader needs that context.

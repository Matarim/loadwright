# Execution Modes — Design Reference

> **Status: specification for software that does not exist yet.** Nothing
> described in this document has been built. Every statement here defines
> *intended* behavior, not current behavior — read it as a build order, not
> as documentation of a working system. When implementation diverges from
> this document, update the document in the same commit.


Loadwright supports two ways of issuing requests, selected by
`config.execution_mode`. This is the most consequential architectural
choice in the gem: it determines what can be measured, how accurate the
measurement is, and how much setup a user needs before their first run.

**Neither mode is strictly better.** They answer different questions, and
the tool's job is to make the tradeoff legible rather than to pick a winner
and hide it.

---

## Mode A — `:in_process` (default)

Requests are issued through `ActionDispatch::Integration::Session` in the
same Ruby process as Loadwright itself. The full Rails middleware stack
runs; the web server does not.

### What it's good at

- **Zero setup.** No server to boot, no ports, no health-check polling.
  `bundle exec loadwright run` works immediately. This matters more than it
  sounds: a tool that requires orchestration before the first result gets
  abandoned during evaluation.
- **Perfect attribution.** Loadwright and the app share a process, so
  `ActiveSupport::Notifications`, `ObjectSpace`, `GC.stat`, and the
  connection pool are all directly readable. Tying a specific SQL query to
  the request that caused it requires no correlation machinery at all.
- **Fast.** No socket, no HTTP parsing, no wire serialization. A full
  scale sweep runs in a fraction of the time.
- **Easy cleanup.** Transactional rollback is available because the
  requests run on the same connection the harness controls.
- **Debuggable.** A `binding.pry` in the app code stops in a process the
  developer is already attached to.

### What it cannot honestly measure

- **Real concurrency.** There is no Puma thread pool, no worker processes,
  no request queueing. Threads inside one process share a GVL. A
  "concurrency 20" number here is not a measurement of anything a user
  would experience.
- **Connection pool exhaustion**, because the pool is being shared with
  the harness rather than contended by real server threads.
- **True client-observed latency**, which excludes socket time, HTTP
  parsing, keepalive behavior, and Puma's queueing.
- **Clean memory attribution**, since Loadwright's own allocations happen
  in the same heap it's measuring.

### The rule that makes this mode safe to use

**Findings that require real concurrency must be reported as
`unavailable in this execution mode`, never as a number.** Not zero, not
"looks fine" — explicitly unavailable, with a one-line pointer to
`:http` mode. This is the same principle as the response validity gate:
never attach a confident label to something you can't stand behind.

Concretely, in `:in_process` mode Loadwright forces
`concurrency_levels = [1]` unless `config.allow_in_process_threading` is
explicitly enabled, and suppresses pool-exhaustion and
latency-under-load findings entirely.

---

## Mode B — `:http`

Loadwright boots (or connects to) a real server — Puma by default — and
issues genuine HTTP requests against it.

### What it's good at

- **Concurrency that means something.** Real threads, real workers, real
  request queueing, real keepalive. A latency cliff at concurrency 20 is a
  cliff the user's clients would actually hit.
- **Connection pool findings become real and reproducible.** The classic
  Rails misconfiguration — Puma `max_threads` exceeding the ActiveRecord
  pool size — only manifests here, and it's one of the most valuable
  things this tool can find.
- **True end-to-end latency**, including everything between the socket and
  the response.
- **Clean memory profile** of the app process, because the harness isn't
  inside it.
- **Can target an already-running server**, including a containerized or
  staging-shaped one (still subject to every safety gate in
  `production-safety.md` — this is not a bypass).

### What it costs

- **Attribution requires machinery.** The harness is in a different
  process and cannot see the app's instrumentation directly. See the
  correlation design below — this is the main implementation cost of the
  mode.
- **Orchestration.** Boot the server, allocate a port, poll until healthy,
  tear down on exit *and* on SIGINT.
- **Harder cleanup.** Transactional rollback isn't available across
  processes; `:delete_created_rows` becomes the only viable strategy.
- **Slower**, both to start and per request.

---

## The seam: three abstractions, not two modes

`execution_mode` is a *user-facing setting*. It is not the axis the code is
organised around, because it conflates two independent things:

1. **`Transport`** — how a request is issued. `InProcess` (ActionDispatch),
   `Http` (real socket), `Null` (scripted; backs `--dry-run` and fast
   tests). Returns a `RawResponse`: status, headers, body, wall-clock
   latency, request id. Knows nothing about instrumentation.
2. **`Collector`** — how per-request metrics come back. `Direct` (shares
   the app's process, reads `ActiveSupport::Notifications` directly),
   `Middleware` (correlated over HTTP, below), `External` (nothing
   app-side; response-derived signals only).
3. **`CapabilityProfile`** — what is measurable, and *why not* when it
   isn't.

**These are not 1:1, which is the whole reason for the split.** `:http`
mode has two collectors: middleware-installed and external-only. An `:http`
run against a remote target that doesn't load the gem has the *same
transport* as a fully-instrumented one and dramatically less capability.

So **capability is a property of the collector, not of the mode.** Anything
deriving "unavailable" from `execution_mode` is wrong in exactly the
degraded-remote case — the case where a confidently wrong number does the
most damage. The capability matrix in `AGENTS.md` §5.1 already says this:
several signals are footnoted "requires collector middleware", not
"requires `:http`".

Concretely:

- Nothing under `analysis/` or `reporting/` may branch on
  `config.execution_mode`. They consult `CapabilityProfile`. A spec
  enforces this; reporting may *display* the mode in run metadata with an
  explicit `# capability-exempt:` marker on the line.
- `ExecutionContext` binds a transport, a collector, and a
  `CapabilityTimeline` into the single object the load engine depends on.

### Capability degrades mid-run

`CapabilityProfile` is a frozen value object. It is not computed once and
held for the whole run, because capability genuinely changes: the collector
middleware can stop responding, and under `:http` the app process can die
outright (`resource-contention.md` Part 7). A profile frozen at run start
would attribute full-capability findings to a window in which collection
had already silently failed.

`CapabilityTimeline` holds the ordered epochs. Every result records the
epoch it was collected under, and the report renders capability per window
rather than making one claim for the whole run. Value semantics are the
point: degrading produces a *new* profile, leaving already-collected
results attributed to the capability actually in effect when they ran.

## The correlation mechanism (how `:http` mode gets its data back)

This is the part that makes Mode B work, and it must be built carefully.

1. Loadwright's railtie installs a middleware into the app — **only when
   the safety guard has approved the run**, never unconditionally on gem
   load.
2. Each outgoing request carries a unique `X-Loadwright-Request-Id`.
3. The middleware records that id in fiber-local state for the duration of
   the request, and a **single, run-scoped** notification subscriber routes
   each event to the right bucket. See the trap below.
4. Cheap summary data (query count, db/view runtime, allocations) comes
   back on response headers. Detailed data (full SQL, stack traces) is
   retrieved by the harness from an internal collection endpoint keyed by
   request ID.

### The trap: subscribe once, not per request

The obvious implementation is for the middleware to call
`ActiveSupport::Notifications.subscribe("sql.active_record")` at the start
of each request and unsubscribe at the end. **This is wrong and will
silently corrupt every concurrent run.** AS::N subscribers are
*process-global*: a subscriber registered by one request receives every
other in-flight request's SQL events too. Under concurrency you get
cross-request metric bleed, and the numbers look plausible.

Correct shape:

- Subscribe **once** at run start, unsubscribe at run end.
- The middleware sets the current request id in
  `ActiveSupport::IsolatedExecutionState` — which honours the host app's
  configured `isolation_level` rather than hand-rolling fiber or thread
  locals. This is why the gem's floor is Rails 7.0.
- The single subscriber reads the current id per event and routes to that
  request's bucket.

**Known limitation, and it must be documented rather than papered over:**
queries issued from a different fiber or thread than the one handling the
request do not carry the id. `load_async`, application-spawned threads, and
explicit futures are all under-attributed — the endpoint's query count
comes out *lower* than reality, which can hide an N+1. This is recorded in
`AGENTS.md` §5.2 as GAP-01 so an agent doesn't report a clean query count
from such an endpoint as proof of absence.

### Security requirements for the collection endpoint

It exposes SQL, stack traces, and timing from the app under test. It is
therefore:

- Mounted **only** while a guard-approved run is active, and unmounted
  after.
- Bound to localhost, and requires a per-run shared secret the harness
  generates at startup.
- Refuses to mount at all if the safety guard has flagged the environment
  as production-adjacent, regardless of other config.
- Subject to the same redaction rules as the report (see `reporting.md`) —
  it should never emit unredacted bind values in the first place.

If the middleware can't be installed (app doesn't load the gem, remote
target), Loadwright falls back to **external-only metrics** — status,
latency, payload size — and marks every query-derived finding as
unavailable rather than silently reporting nothing. A degraded run must
announce its degradation.

---

## Choosing a mode: real-world scenarios

| Scenario | Mode | Why |
|---|---|---|
| Writing an endpoint, want to know if it has an N+1 | `:in_process` | N+1, over-fetch, and pagination are all single-request properties. Concurrency adds nothing and costs setup time. |
| Pre-merge check on a feature branch | `:in_process` | Fast, no orchestration, catches the majority of findings. |
| "Is my connection pool sized right for my Puma config?" | `:http` | Only observable with real server threads. |
| "Where does this endpoint fall over — 10 users? 50?" | `:http` | In-process concurrency numbers would be actively misleading here. |
| Pre-release sanity check against a staging-shaped box | `:http` | Real stack, real latency, closest to what clients see. |
| Comparing two branches for query-count regressions | `:in_process` | Query counts are deterministic and mode-independent; the faster mode wins. |
| Investigating GC pressure or memory bloat | `:http` | Clean process-level memory attribution. |

The honest summary: **`:in_process` finds most *correctness* problems in
query structure; `:http` finds *capacity* problems.** Most developers most
of the time want the first. The default reflects that, and the README
should say so plainly rather than implying the heavier mode is the "real"
one.

---

## Cross-mode consistency requirements

- Every report states which mode produced it, prominently in the metadata
  header. A reader must never have to guess.
- Run comparison (`run-comparison.md`) **refuses to compare across
  modes.** Latency from `:in_process` and `:http` are different
  quantities; presenting a delta between them would be meaningless. Query
  counts *are* comparable, so a cross-mode comparison may optionally
  proceed on query metrics alone, clearly labelled as partial.
- The same endpoint set, seeding, and analysis pipeline must work in both
  modes. Mode changes *how requests are issued and how metrics are
  collected*, and nothing else. Resist any design where a feature exists
  in only one mode without an explicit "unavailable" path in the other.

## Orphan reaping (`:http` only)

`Lifecycle` teardown covers SIGINT and normal exit. It cannot cover
`SIGKILL`, a laptop sleeping, or a terminal dying — and in those cases the
booted server survives the harness and keeps holding the user's development
database. A diagnostic tool that leaves a stray process on someone's machine
holding their dev DB has made their environment worse than it found it,
which is the same category of harm the safety design exists to avoid.

Reuse the per-run directory created for the collector secret:

Write a pidfile alongside the secret recording **two identities** — the
server's and the harness's — each as PID plus process start time, plus the
hostname. Reap before booting anything, since the exit path is precisely the
one a killed run never reached.

Three rules, each present because of a specific way reaping could do harm:

- **Never kill on PID alone.** The recorded start time must match, or a
  recycled PID gets killed on the strength of a coincidence.
- **Never kill a server whose harness is alive.** That's a concurrent run,
  not an orphan. This is why the pidfile records two identities: matching
  only the server's PID and start time would reap a healthy server belonging
  to a run happening right now.
- **A directory whose server is gone is litter.** Remove it, kill nothing.

Two fail-safety details:

- **A zombie is not running.** It still appears in the process table, so a
  check that reads the table rather than the process *state* will wait
  forever on something already dead. A zombie holds no port and no
  connection.
- **An unverifiable record fails toward not killing.** If start time can't
  be read, record `"unknown"` rather than omitting the field — the pidfile
  stays parseable and the comparison can never match. Same for a hostname
  that isn't this machine: not ours to act on.

**Process groups are not a substitute for this.** Spawning the child with
`pgroup: true` lets the harness signal the whole tree on a clean stop, which
is why it's there — but nothing portable makes a child die with its parent
(`PR_SET_PDEATHSIG` is Linux-only, and the child is an arbitrary command
that won't watch a pipe for us). The interactive case is covered by
`Lifecycle`'s SIGINT trap. Reaping is therefore not a backstop to the
process group; it is the mechanism for the one case nothing else reaches.

The governing principle matches the secret file's: a leftover artifact
should be self-evidently dead and cleanable, not merely unlikely to matter.

Note this is the only place Loadwright terminates a process, and the scope
is narrow by construction: **its own orphaned children, recorded in its own
run directories.** It never terminates database sessions (see
`resource-contention.md`) and never anything it did not spawn.

## Testing requirements

- A spec proving `:in_process` mode suppresses concurrency-dependent
  findings rather than reporting fabricated values for them.
- A spec proving the `:http` collection endpoint is unmounted after a run
  and refuses to mount in a production-flagged environment.
- A spec proving request-ID correlation returns the correct per-request
  metrics under concurrent load (the obvious failure mode is cross-request
  metric bleed — test it deliberately with overlapping requests).
- A spec proving fallback to external-only metrics marks query findings
  unavailable rather than reporting zero.
- A spec proving the same transport with different collectors yields
  different capability — `:http` + middleware vs `:http` + external — so a
  regression that re-keys capability off `execution_mode` fails loudly.
- A spec proving a mid-run capability downgrade opens a new epoch and that
  results collected before it retain their original attribution.
- A spec proving the whole analysis pipeline runs on the `Null` transport
  with a scripted collector, so the fast tests genuinely exercise it. Paired
  with at least one real end-to-end run per transport against
  `examples/sample_app/` — test doubles drift from reality, and a suite that
  only ever runs against doubles will stay green while the real path breaks.
- A spec proving SIGINT during an `:http` run still tears down the server,
  cleans seeded rows, and writes a partial report.

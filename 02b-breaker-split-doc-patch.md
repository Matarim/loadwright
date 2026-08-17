Small scoped follow-up before we move on. **Documentation only — do not
implement any new features, do not start any subsystem you haven't already
finished, and do not refactor code.** If you find yourself editing anything
under `lib/`, stop.

The prompt you worked from was missing an addendum to step 8. When the
structural breaker/guard split landed, two documents became not merely
stale but actively wrong — they still instruct the reader to apply the
manual workaround the split eliminated.

## First, verify the premise

Check whether the structural split is actually implemented: are the Tier 1
contention exception classes (`LockWaitTimeout`, `Deadlocked`,
`StatementTimeout`, `QueryCanceled`, `ConnectionTimeoutError`, and
`StatementInvalid` wrapping any of them) routed to the resource guard and
**excluded from the circuit breaker's error-rate numerator**, with both
counts reported separately?

- **If yes** → proceed with the edits below.
- **If no, or only partially** → stop and tell me exactly where step 8 got
  to. Don't make these doc edits describing behavior that doesn't exist
  yet, and don't implement the split now to make the docs true — I'd rather
  know where things actually stand.

## Edit 1 — `resource-contention.md` §6

The tuning section currently frames breaker-vs-guard conflict as something
the user manages by threshold tuning: "keep `max_error_rate_before_abort`
above the error rate contention produces."

Rewrite it as a statement of the structural split instead. The two
mechanisms own disjoint failure classes — the breaker means "this endpoint
is broken" (wrong auth, missing route, 500s), the guard means "the database
is under pressure" (lock waits, pool exhaustion, statement timeouts) — and
the code classifies which is which. Keep the tuning table itself; it's the
"critical interaction" framing that's obsolete.

Also document the two attribution carve-outs, since they're the cases where
a contention error *is* an endpoint finding and shouldn't disappear into
"the database was under pressure":

- **Repeat offender**: blocker was ours, same endpoint across multiple
  cells → an endpoint finding, not only guard telemetry.
- **Pool exhaustion at concurrency 1**: `ConnectionTimeoutError` under real
  concurrency is load pressure; the same error at concurrency 1 is almost
  certainly an application connection leak. Classify on concurrency level.

## Edit 2 — `AGENTS.md`

Two known spots, but grep the whole file rather than trusting this list —
the old advice may be referenced from places I haven't seen:

- **`DIAG-10`** — currently `fix: RAISE max_error_rate_before_abort (e.g.
  0.20 -> 0.35)`. That tells an agent to loosen a safety threshold to work
  around something now handled in code. Replace with: contention errors
  don't count toward the breaker, so this symptom means something else is
  producing errors — check the guard's own escalation and the separately
  reported contention count.
- **§12 `critical_interaction`** — same problem, same fix.

Then grep for `max_error_rate_before_abort` and `DIAG-10` across the file
and correct any cross-references that assumed the old behavior.

While you're in `AGENTS.md`, add a diagnostic for the *new* symptom this
creates: a run that aborts on the circuit breaker with a high contention
count reported separately. Under the old model that was one confusing
signal; under the split it's two distinct ones, and an agent should know to
read them separately rather than conflating them.

## Constraints

- These are documentation edits. No `lib/` changes.
- Commit them separately from step 8's implementation commit, with a message
  making clear this is a correction to docs that described pre-split
  behavior.
- Don't touch any other section of `AGENTS.md`. It has a broader
  verification pass scheduled for the final session, and I don't want that
  work started early and half-done — in particular leave the
  `STATUS: SPECIFICATION_ONLY` marker in place.
- When done, tell me what you changed and whether the grep turned up
  anything beyond the two spots I named.

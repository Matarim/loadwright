Continuing work on Loadwright. Re-read CLAUDE.md (especially section 6)
and `.claude/skills/loadwright-development/SKILL.md` before starting. This
session covers the analysis signals that go beyond query counting, plus
run history and comparison.

Everything here lives under `analysis/` and `history/`, so the seam rules
from session 01 apply throughout and are worth restating:

- **No code in this session may reference `config.execution_mode`.** Signal
  availability comes from `CapabilityProfile`. There's a grep spec enforcing
  this; if you find yourself wanting to branch on the mode, that's the
  signal you need a capability instead.
- **Every signal emits `Measurement`**, never a bare number or `nil`. An
  unavailable signal is `Measurement.unavailable(reason)` with a reason a
  human can act on — "no collector middleware," not blank.
- **Capability is per-window, not per-run.** `CapabilityProfile` records
  mid-run downgrades, so a signal can be available for the first 200
  requests and unavailable after. Attribute to the profile in effect when
  each request ran.
- **Teardown registers with `Lifecycle`.** Nothing in this session traps
  signals itself.

**Two small carry-overs from the reaping work first.**

1. **Record the hostname in the pidfile**, and skip records from other
   hosts during the reap scan. `Dir.mktmpdir` is local in the normal case,
   but `TMPDIR` pointed at a shared or network volume would let two machines
   see each other's run directories — and a PID plus start time can collide
   across hosts in a way it can't within one. Same fail-toward-not-killing
   principle as the unknown-start-time case: a record we can't attribute to
   this machine is not ours to act on.

2. **Make the kill-scope distinction explicit in `AGENTS.md`.** `INV-11`
   says Loadwright never kills sessions, and `DIAG-10e` now tells an agent
   that reaping kills an orphaned server. Those read as contradictory
   without the distinction stated: we terminate **our own orphaned child
   processes, recorded in our own run directories**; we never terminate
   database sessions, and never anything we didn't spawn. Put that line
   beside `INV-11` rather than only in `DIAG-10e`, since an agent scanning
   the invariants may not reach the diagnostic. This is exactly the kind of
   apparent contradiction that produces a confidently wrong refusal.

**Then — the detector-activation transition.** Two finding
classes are currently `not_applicable` because their detectors don't exist:
`index_scan` (no `ExplainAnalyzer`) and `latency` (no `Statistics`). This
session ships both, which flips those classes from "never attempted" to
live. Expect endpoints that read `healthy` at the end of session 02 to
change state, and treat that as a deliberate, observed transition rather
than a surprise:

- Run the full fixture sweep **before** shipping either detector and record
  the state distribution.
- Ship them, re-run, and diff. Endpoints moving `healthy` → `has_findings`
  are the detectors working. Endpoints moving `healthy` → `inconclusive`
  mean the detector shipped but can't answer — verify that's genuinely the
  app's fault (EXPLAIN unavailable on the adapter, sample size too low) and
  not a wiring bug making a live detector report `unavailable` when it
  should be returning a result.
- A mass migration to `inconclusive` is the failure mode to watch for. If
  more than a handful move, stop and diagnose before continuing.

Also add the guard that keeps `not_applicable` from becoming a laundering
mechanism: **a detector enabled in config must never return
`not_applicable`.** If it's enabled and can't answer, that's `unavailable`
with a reason. Spec it now, while there are two fresh detectors to test it
against.

1. **Performance signals** (`references/performance-signals.md`), in this
   order:

    - **Time breakdown** — if instrumentation already captures
      db/view/GC/external, finish the attribution and the "everything else"
      bucket. The containment-skew disclosure is required, not optional: a
      run with outbound HTTP blocked is faster than reality and the report
      must say so. Also surface jobs-enqueued-per-request; a request
      enqueuing 200 jobs is a finding.
    - **EXPLAIN / index analysis.** Runs *after* the load phase, on a
      separate connection, never during. The safety rule here is the one to
      get right: `EXPLAIN ANALYZE` executes the statement, so it's
      SELECT-only — anything else gets plain `EXPLAIN`, or `ANALYZE` inside
      an explicitly rolled-back transaction. Write a spec proving a write
      statement is never executed by the analyzer.
    - **Cold vs warm cache** — measure both rather than discarding the cold
      pass, and label it "application-cache cold" rather than overclaiming
      what we can actually reset.
    - **Pool vs server threads** — flag `threads × workers > pool_size` as a
      static config finding even when no contention was observed. Note this
      signal is *partial* rather than absent under `InProcessTransport`: the
      static config comparison works, the observed-contention half doesn't.
      That's two different `Measurement` results from one check, not one
      blanket unavailable.
    - **Statistical validity** — omit percentiles the sample size can't
      support, with the required N stated. Report sample counts and
      coefficient of variation. No p99 from 25 samples.

2. **Traffic realism** (same reference doc, Part 6) — the identity pool so
   we're not hammering one user's rows, plus detection for the two most
   likely first-run failures: rate limiting throttling the run (cluster of
   429s / `Retry-After`) and uniform 401/403 meaning `auth_token_provider`
   isn't wired up. Both should produce a plain-language diagnosis, not a
   report full of unexplained `inconclusive`.

3. **Redaction** (`references/reporting.md`, redaction section) — build
   this *before* run persistence, because it has to happen at collection
   time so secrets never reach the persisted record in the first place.
   Honor `Rails.application.config.filter_parameters`, redact auth
   headers, strip SQL bind values, response bodies off by default.

   Two places redaction has to reach that aren't obvious: the `reason`
   strings inside `Measurement.unavailable(...)` and the cause fields on
   `CapabilityProfile` downgrade events. Both can end up carrying hostnames,
   target URLs, or connection details, and both get persisted. Redact them
   on the same path as everything else rather than treating them as internal
   metadata.

4. **Run history and comparison** (`references/run-comparison.md`) —
   persisted run records, baselines, and `loadwright compare`. Register run
   persistence with `Lifecycle` so an interrupted run still leaves a usable
   record — a partial run record is often the most interesting one, and it's
   what the next session's partial-report path reads from. Two things
   I care about most here:
    - **The comparability gate**, with two corrections from session 01.
      First, **fingerprint on resolved config values, not assigned ones** —
      `Configuration` tracks provenance now, and two runs with identical
      explicit config but different preset resolution must not fingerprint as
      comparable. Second, **the gate compares `CapabilityProfile`s, not just
      config.** Two runs with identical config aren't comparable if one
      degraded mid-run and lost query collection; the intersection of their
      capabilities is what's actually comparable, and anything outside it is
      excluded from the delta rather than silently compared. Say which
      dimension diverged either way — a plausible-looking meaningless delta
      is worse than no comparison.
    - **Query counts are the primary signal, latency is mostly noise.**
      Laptop latency moves 10–20% between identical runs; a query count
      going from 3 to 47 is unambiguous. Latency deltas need to clear both
      the threshold and the measured noise floor before being called
      regressions — everything else is labelled "within noise."

   Also handle the state-transition case: an endpoint moving from
   `healthy` to `inconclusive` hasn't improved, and findings disappearing
   because an endpoint stopped being measurable must not read as a fix.

Same working conventions as before: specs alongside implementation,
commits scoped per subsystem, CLAUDE.md section 6 updated as you go, and
stop and ask rather than guessing on anything the reference docs leave
ambiguous. Don't start reporting or the README — that's the next session.

At the end, summarize what's implemented, what the tests cover, and
anything you'd flag as still-rough.
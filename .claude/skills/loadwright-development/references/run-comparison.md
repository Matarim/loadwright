# Run Comparison & Regression Detection — Design Reference

> **Status: specification for software that does not exist yet.** Nothing
> described in this document has been built. Every statement here defines
> *intended* behavior, not current behavior — read it as a build order, not
> as documentation of a working system. When implementation diverges from
> this document, update the document in the same commit.


The question developers actually ask is not "is this endpoint slow." It's
**"did my change make it worse?"** A tool that produces a one-shot report
with no memory can't answer that, which is why every APM leads with
trend and comparison views.

## Run persistence

Every run writes a structured record to `config.run_history_dir` (default
`tmp/loadwright/runs/`), independent of the human-readable report:

- Run ID (timestamp + short hash)
- Git SHA, branch name, and **dirty-worktree flag** — a run from
  uncommitted code is still useful, but a comparison against it needs a
  caveat
- Full resolved config snapshot
- Execution mode
- Machine fingerprint: CPU count, available memory, OS, Ruby version,
  database version
- Per-endpoint metrics, findings, and outcome states
- Which containment measures were active

Retention is bounded by `config.run_history_limit` (default 50), pruning
oldest first. Runs may contain sensitive data, so they inherit the same
redaction rules as reports (`reporting.md`) and the generator adds the
history directory to `.gitignore`.

## Commands

```
loadwright compare <run_a> <run_b>
loadwright compare --baseline          # current run vs designated baseline
loadwright baseline set <run_id>
loadwright runs list
```

## Comparability gate — refuse rather than mislead

**One dimension is not in the config fingerprint**, and has to be checked
separately: the app's own default page size. The seed-scale sweep deliberately
sends no page-size parameter (see `response-analysis.md`), so what it holds
fixed is whatever the app defaults to — a property of the *app*, not of the
config. A run before and after a change to that default is not comparing the
same thing even though both fingerprints match. The observed value per endpoint
is recorded in run metadata as `sweeps.seed_scale.observed_page_size`; treat a
change in it the way you treat a change in `page_size_sweep`.


Two runs are only comparable if their config fingerprints match on the
dimensions that affect measurement: **execution mode, scale factors,
concurrency levels, requests per cell, containment settings, and the
endpoint set.**

The fingerprint is computed over **resolved** values, not assigned ones — a
contention preset changes resolved timeouts without changing a single
explicit assignment. The comparator compares the resolved values themselves
rather than only the digests, so the refusal can name *which* key diverged.

**A third dimension: capability.** Two runs with identical config are not
comparable on query counts if one of them degraded mid-run and lost query
collection — same fingerprint, dramatically less data. This one does *not*
refuse the whole comparison. The **intersection** of the two runs'
capabilities is what gets compared, and any metric outside it is **excluded
from the delta and named**, never silently compared against a missing
number. (Config and page-size divergence still refuse outright: those change
what was measured, where a capability gap changes only how much of it we
can see.)

If they differ, Loadwright **refuses to compute regressions** and says
exactly which dimension diverged. Comparing a run at concurrency 20 to one
at concurrency 5, or an `:http` run to an `:in_process` run, produces
numbers that look meaningful and aren't. This gate is the difference
between a comparison feature and a misinformation feature.

Softer mismatches produce warnings rather than refusal:

- Different machine fingerprint → latency deltas are unreliable, query
  deltas are fine. Say so.
- Dirty worktree on either side → the SHA doesn't fully describe the code.
- Different endpoint sets → compare the intersection, list what was
  added/removed rather than silently dropping it.

## Query counts are the primary signal, not latency

This is the central design insight of this subsystem.

**Query count is close to deterministic.** An endpoint that went from 3
queries to 47 has unambiguously regressed, and that fact is reproducible on
any machine, in any mode, under any load. It needs no statistical
treatment.

**Latency on a developer laptop is noisy.** Background processes, thermal
throttling, disk cache state, and other applications routinely move p95 by
10–20% between identical runs. Treating a 15% latency increase as a
regression will produce false alarms constantly, and a comparison tool that
cries wolf gets ignored within a week.

Therefore:

- Query count, returned-record count, and payload size deltas are reported
  as **findings** at any change beyond a small tolerance. (Allocation counts
  are *not* compared: they are not persisted per cell. Nothing should claim
  they are.)
- Latency deltas are reported as findings only when they exceed
  `config.regression_threshold_pct` (default 20%) **and** exceed the
  measured run-to-run variance.
- Anything below those bars is explicitly labelled **"within noise"** —
  shown, because the developer may still want to see it, but never
  presented as a regression.

### A query count needs its denominator

A query count only means something next to the number of records that
produced it, and this is where the primary signal can quietly lie.

Narrow a scope, break a filter, or lower a page-size cap, and a collection
endpoint returns 5 records where it used to return 30. Queries fall 31 → 6.
Read on its own that is a 39% improvement and looks like an N+1 being fixed.
It is nothing of the kind — it is the same queries-per-record over less data,
and the endpoint is arguably broken.

So a query delta whose cell's record count also moved is reported with
**neither** verdict. It is shown, in its own section, with the reason; the
number is real, the comparison is not. A *drop* in returned records at an
unchanged scale factor and page size is separately a regression in its own
right, because an endpoint that stopped returning things is a defect however
fast it got.

Absent record counts on both sides are not a change: error responses carry
none, and neither do run records written before the field existed. Treating
absence as movement would strip the verdict off every comparison against an
older run.

This is deliberately *per cell*, and it does not replace the run-level
observed-page-size gate — that one samples only the largest scale factor's
seed-scale cells, so record counts can still move in a page-size-sweep cell
or at a smaller scale without tripping it. The two are complementary.

### Establishing the noise floor

`loadwright baseline set` should encourage running the baseline **twice**
on the same commit and recording the observed variance between them. That
variance becomes the noise floor for subsequent comparisons on that
machine. Without this, `regression_threshold_pct` is a guess; with it, the
tool knows what "normal jitter" looks like on the hardware it's actually
running on.

As built: `baseline set` looks for a second run with the same git SHA *and*
the same config fingerprint, and records the widest relative gap between
their paired cells as the floor. Finding none, it says so and names the fix
rather than fabricating a number, and comparisons fall back to
`regression_threshold_pct` alone. The floor is stored **with the baseline
pointer**, not globally — it is a property of this machine measured on this
commit. The bar a latency delta must clear is `max(threshold, floor)`, so a
quiet machine never *lowers* the configured bar.

One presentation detail that falls out of "shown, never called a
regression": a change under 5% is not listed at all. A row reading
"p50 latency: 100.0 → 100.0, within noise" is padding that buries the rows
that matter.

## What a comparison report contains

- **New findings** — problems present in B that weren't in A. The headline
  section.
- **Resolved findings** — problems in A that are gone in B. Equally
  important; it's how a developer confirms a fix worked.
- **Changed magnitude** — same finding, different severity.
- **Within-noise changes** — shown separately, never as regressions.
- **State transitions**, which need explicit handling: an endpoint that
  moved from `healthy` to `inconclusive` has not improved and has not
  regressed — it became unmeasurable, and that's its own event worth
  surfacing. The comparison must not treat the disappearance of findings
  from an endpoint that stopped being measurable as a fix.

  As built, this is two things rather than one. The transition is surfaced
  on its own terms *and* each disappeared finding is marked
  `resolved: false` with a note saying nothing was measured to fix — because
  a reader scanning the RESOLVED section is exactly the reader who would
  otherwise conclude their fix worked.

  Resolved findings are also **not netted against** new ones: a fix and a
  regression in the same run are two facts, not zero.
- **Endpoints added/removed** between runs.

## Exit codes

`loadwright compare` exits non-zero when new findings appear, gated by
`config.fail_on_regression` (default `false`, consistent with the rest of
the tool's report-first posture). Even where someone wires this into a
script, the comparability gate still applies — a comparison that can't be
computed is an error, never a silent pass.

As built:

| code | meaning |
|---|---|
| `0` | comparable; no regressions, or `fail_on_regression` is false |
| `1` | comparable; regressions found and `fail_on_regression` is true |
| `2` | **not comparable** — the runs diverge on a measurement dimension |

`2` is deliberately distinct from `1`. A script that treats "could not
compare" as "passed" is the silent-pass failure this gate exists to
prevent, and one that treats it as "regressed" would cry wolf.

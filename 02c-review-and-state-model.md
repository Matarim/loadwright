Reviewed. Good session — the fixture numbers are exactly what I wanted:
flat 26 queries across seed scale 30→90, rising 6/26/51 against page size
5/25/50. That's the Part 2 blind spot demonstrated on a real app instead of
asserted on invented numbers, and 1+N at every page size is unmistakable.

Run `02b-breaker-split-doc-patch.md` first if you haven't — it's doc-only
and scoped. Then this.

## Answer to your open question: not-measurable is not a finding

`has_findings` with `confidence: :none` is the wrong home, and you're right
to be uneasy about it. Two problems: it inflates the finding count, and
"finding" implies something is wrong with the *app* when what's actually
true is that something is wrong with our *coverage*. A zero-confidence
finding is a category error — unavailability belongs in `Measurement`, which
is what it's for.

But `inconclusive` for the whole endpoint is too strong in the case you
describe. Every other signal measured fine; flooding reports with
`inconclusive` for one unmeasurable signal makes the state meaningless,
which is its own failure.

**The rule: derive outcome state from finding-class coverage, not from
signal count.**

Each finding class has one or more detectors, and a class is *covered* if at
least one of its detectors was measurable:

- N+1 → pattern-match detector, slope detector
- Missing pagination → payload growth
- Over-fetch → query/response key comparison
- Index/scan → EXPLAIN
- Latency → percentiles at adequate sample size

Then:

- **All classes covered, no findings** → `healthy`
- **Any finding** → `has_findings`
- **Any class with zero coverage** → `inconclusive`, naming the uncovered
  class

So your case — slope not measurable, but the pattern-match detector ran and
came back clean — is **`healthy`**. The N+1 class was covered; we just
covered it with one detector instead of two. If *both* N+1 detectors were
unavailable, you genuinely cannot rule out an N+1 and it's `inconclusive`.

One addition that makes this honest rather than merely tidy: **report
per-class coverage on every endpoint regardless of state.** Something like
"checked: N+1 (pattern only), pagination, over-fetch — not checked: index
analysis (EXPLAIN unavailable)." That's cheap, it's more informative than
any single state label, and it means a reader can see reduced coverage
without us having to overload `inconclusive` to signal it. Fold coverage
into `EndpointOutcome` so reporting renders it rather than recomputing it.

### Two doc edits go with this

Both are gaps in my docs, not just implementation choices, so make the edits
rather than only the code change:

- **`response-analysis.md`** — add the coverage-derived state rule: the
  finding-class → detectors table, the three derivations, the worked case
  (slope unmeasurable + pattern-match clean → `healthy`), and the statement
  that per-class coverage is reported regardless of state.
- **`AGENTS.md` §9.1** — add `state_derivation` and `coverage_map` blocks so
  an agent reading only that file reaches the same conclusion. The
  consequence to state explicitly, because it's the one an agent will get
  wrong: reduced coverage on an otherwise-clean endpoint is neither a
  finding nor `inconclusive`. Leave the rest of `AGENTS.md` alone —
  including the `STATUS: SPECIFICATION_ONLY` marker — since it has a full
  verification pass scheduled for the final session.

## Review items

**1. The env var carrying the collector secret.** Arming the child through
its environment is the right mechanism — nothing else reaches another
process, and having the railtie still consult the guard is correct, since an
env var isn't authorisation. But if the per-run shared secret travels in an
env var, it's readable by any local user via `ps` on most systems, and env
vars leak into crash dumps and process logs. Pass a path to a mode-0600
file, or hand it over stdin at boot, and keep only the *path* in the
environment. Tell me which you pick.

**2. `EnvironmentGuard`'s injectable `rails_env` needs a fence.** The
injection is justified — you found 22 silently-disabled guard examples with
it, which is precisely the kind of thing that should never sit undetected in
this subsystem. But an injection point on the environment guard is also
exactly what a careless future change would reach for to bypass the gate.
Add a spec asserting the injection is unreachable from `Configuration`,
from ENV, and from the CLI — test-only, no production path. A comment
saying "test only" is not a fence.

**3. The 22 disabled examples imply an audit, not just a fix.** If 22 safety
examples were passing vacuously, others may be too. For each safety-critical
behavior — each of the four Layer 3 conditions, each Layer 1b case, the
dry-run gate, the kill-statement prohibition, containment abort — verify the
spec **fails when the behavior is removed.** Temporarily break each one and
confirm red. Report anything that stayed green; that's a spec testing
nothing. This is the only way to know the guard suite is real.

**4. The `openapi3_parser` raw-hash path is version-fragile.** Bypassing
`Node::Schema#to_h` because it's shallow and injects
`additionalProperties: false` is the right call — using it would reject
valid responses and mark healthy endpoints schema-invalid, which is a
false-inconclusive at scale. But you're now depending on the shape of an
internal parsed hash rather than public API. Pin a conservative version
constraint, and add a spec that fails loudly if the hash shape changes on a
gem upgrade rather than silently degrading validation.

**5. Confirm the 3.1 failure is loud, not partial.** Your empirical finding
is useful — accepts a `3.1.0` version string, then rejects webhooks, type
arrays, numeric `exclusiveMaximum`. The question that matters: when it hits
one of those, does discovery **raise**, or does it skip that operation and
continue? If it skips, we produce a short endpoint list, and endpoints that
were never tested get reported as absent rather than skipped — the tool
would tell someone their API is clean when it never looked at part of it.
Verify which happens and make it raise if it doesn't already.

**6. Document the two sweep decisions you had to invent.** Page-size sweep
at concurrency 1, and seed-scale sweep sending no page-size param — both
follow correctly from one-axis-fixed, and both belong in the docs now rather
than living only in code. Also record the app's *default* page size in run
metadata for the seed-scale sweep, since the comparability gate needs it:
two runs against apps with different defaults aren't comparing the same
thing.

**Unknown blocker → external** is the right call. Costing a finding to avoid
a false accusation is the correct direction, and it matches the asymmetric
trust rule from Layer 1b.

## Scope

Items 1–6 plus the coverage-state change. Don't start the reporting layer,
performance signals, or run history — those are the next two sessions, and I
want the state model settled before report templates encode it, which is
your own point and it's a good one.

Commit the coverage-state change separately from the review items; it
touches the data model and I want it isolated in history.

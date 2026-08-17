# Response Correlation & Query Structure Analysis — Design Reference

> **Status: specification for software that does not exist yet.** Nothing
> described in this document has been built. Every statement here defines
> *intended* behavior, not current behavior — read it as a build order, not
> as documentation of a working system. When implementation diverges from
> this document, update the document in the same commit.


Query counts alone cannot tell you whether an endpoint is well-built. The
response is the other half of the equation, and without it Loadwright will
confidently produce wrong answers.

**The failure mode this subsystem exists to prevent:** an endpoint that
returns `403 Forbidden` in 4ms with 1 query looks, to a purely
query-counting tool, like the healthiest endpoint in the entire API. It
will rank at the top of a "clean" list. An endpoint returning an empty
array because the seeded records didn't match its scope looks identical to
one that's genuinely well-optimized. Reporting either as clean is worse
than reporting nothing at all, because the developer now believes something
false about their app.

So: **no endpoint may be reported as healthy unless its response proves it
actually did the work.**

## Part 1 — Validity gate (runs before any other analysis)

For each response, before computing a single performance signal, check:

1. **Status code is a success** for the operation. A `4xx`/`5xx` means you
   measured an error path, not the endpoint.
2. **Response validates against the OpenAPI schema**, when a schema exists
   for that operation. A response that doesn't match its declared contract
   means either the doc is stale or the endpoint is misbehaving — either
   way the measurement is untrustworthy.
3. **The response is non-empty when seeding implies it shouldn't be.** If
   Loadwright seeded 200 posts and `GET /posts` returns `[]`, the seeded
   records didn't match the endpoint's scope (wrong tenant, wrong
   `published` flag, soft-deleted, wrong user association). This is a
   *setup* problem, not a performance result.
4. **Response shape is consistent across scale factors.** If the endpoint
   returns a different structure at scale 10 vs scale 200, cross-scale
   comparison is invalid.

Any failure → the endpoint is marked **`inconclusive`** with the specific
reason, and is excluded from the "clean" list, the summary rankings, and
any pass/fail exit code. `inconclusive` must be visually distinct from both
"healthy" and "has findings" in the report — three states, not two.

`config.require_successful_response` and
`config.require_schema_valid_response` control the strictness of items 1–2
(both default `true`), but even when relaxed, the report must still label
what it measured.

## Part 2 — Queries per returned record

The single most useful response-derived signal.

Parse the response body, count the records in each collection (top-level
and nested), then compute `total_queries ÷ returned_record_count`.

- Ratio near-constant and low (1–3) → healthy.
- Ratio constant but high, with total queries tracking record count → N+1
  signature, confirmed independently of both the pattern-match and slope
  signals.
- Ratio that *drops* as records increase → likely healthy batching.

### An important correction to the scale-factor heuristic

`discovery-and-load-engine.md` describes measuring query count against the
**seeded** scale factor. That heuristic has a blind spot this subsystem
fixes: **a properly paginated endpoint will show a flat query count as
seeded data grows, even if it has a severe N+1 on the 25 records it
returns.** Seed 10 or seed 10,000 — it still returns one page, so the slope
looks perfect.

Therefore the slope must be measured against **returned record count**, not
seeded count, and where the endpoint supports a page-size parameter,
Loadwright should vary *that* (`config.page_size_parameters`, e.g.
`per_page`, `limit`, `page[size]`) across its scale sweep in addition to
seeding. Endpoints where returned count never changes regardless of seeding
or page-size params should be flagged as "unable to vary result size —
N+1 slope not measurable," not as flat/healthy.

### Matrix shape — two sweeps, one axis fixed in each

These are two different questions, and running them as one combined matrix
makes the resulting slope unattributable: if seeded rows and page size both
change between cells, a rise in query count cannot be assigned to either.

**Never vary both axes in one sweep.**

| Sweep | Vary | Hold fixed | Question it answers |
|---|---|---|---|
| Seed-scale | `scale_factors` | page size | Does query **cost** grow with table size? Index and scan behaviour — this is what pairs with EXPLAIN analysis. |
| Page-size | `page_size_sweep` | seed scale, at a value high enough to fill several pages | Does query **count** grow with records returned? This is the N+1. |

The seed scale held fixed during the page-size sweep must be large enough
that the largest page size in `config.page_size_sweep` is actually filled.
Sweeping page sizes of 5/25/100 against 30 seeded rows measures the same 30
records three times and produces a flat line that means nothing.

#### Two consequences of one-axis-fixed, both decided rather than emergent

**The seed-scale sweep sends no page-size parameter at all.** Holding page size
fixed at some arbitrary value would satisfy the letter of the rule, but not at
a value any client uses. Sending nothing measures the endpoint *as it is
actually called* — which is also what lets an unpaginated endpoint reveal its
payload growth, since the whole collection comes back.

The consequence for comparability: what "fixed" means is then **the app's own
default page size**, which is a property of the app and not of the run. Two
runs against apps with different defaults are not comparing the same thing, so
the observed default is recorded in run metadata
(`sweeps.seed_scale.observed_page_size`, derived from the returned record count
at the largest seed scale) and the comparison gate treats a change in it the
way it treats a change in `page_size_sweep`.

**The page-size sweep runs at concurrency 1.** Queries-per-returned-record is a
single-request property. Varying concurrency alongside page size would
reintroduce exactly the unattributable-slope problem the split exists to avoid
— a rise in query count could be the page size or the contention. Concurrency
belongs to the seed-scale sweep, where it is the axis under test.

This is a hard requirement on the load engine's matrix construction, not an
implementation detail left to emerge — see `discovery-and-load-engine.md`
Part 3.

## Outcome state is derived from coverage, not from signal count

Part 1 decides whether a response can be measured at all. This decides what to
call an endpoint once it has been.

**An unmeasurable signal is not a finding.** An earlier version of this design
emitted a zero-confidence "finding" when a signal could not be computed — for
instance when result size could not be varied and the N+1 slope was therefore
unavailable. That is a category error twice over: it inflates the finding
count, and the word *finding* says something is wrong with the **app**, when
what is actually true is that something is missing from our **coverage**.
Unavailability belongs in `Measurement`, which exists for exactly that.

But `inconclusive` for the whole endpoint is too strong in that case. Every
other signal measured fine. Flooding a report with `inconclusive` for one
unmeasurable signal makes the state meaningless, which is its own failure —
the same failure the three-state model exists to prevent, relocated.

### Finding classes and their detectors

A finding *class* is a kind of problem. Each class has one or more
**detectors**, and a class is **covered** if at least one of its detectors was
measurable. Redundancy is not a requirement.

| Finding class | Detectors |
|---|---|
| N+1 | pattern-match (duplicate fingerprints), slope (queries vs returned records) |
| Missing pagination | payload growth against seeded scale |
| Over-fetch | queried tables vs response keys |
| Index / scan | `EXPLAIN` |
| Latency | percentiles at adequate sample size |

### The three derivations

- **All classes covered, no findings** → `healthy`
- **Any finding** → `has_findings`
- **Any class with zero coverage** → `inconclusive`, naming the uncovered class

Findings take precedence over a coverage gap. A concrete defect is the most
actionable thing the tool can say, and the gap stays visible regardless
because coverage is reported either way.

The validity gate in Part 1 runs *before* this. A response that did not prove
it did the work is `inconclusive` for that reason, and no coverage question
arises.

### The worked case

An endpoint whose N+1 slope is not measurable (result size could not be
varied) but whose pattern-match detector ran and found no repeated fingerprint
is **`healthy`**. The N+1 class was covered — with one detector instead of
two. Nothing about the missing slope changes what can honestly be said.

If **both** N+1 detectors were unavailable, an N+1 genuinely cannot be ruled
out, and the endpoint is `inconclusive`.

### Three detector states, not two

The distinction that keeps this from flooding:

| State | Meaning | Effect |
|---|---|---|
| `available` | Ran, produced a usable answer | Covers its class |
| `unavailable` | Attempted, could not answer | A real coverage gap |
| `not_applicable` | Never attempted — subsystem absent, or disabled by config | Reported, but not a gap |

The line between the last two is **who prevented the answer**. `unavailable`
means the app or its data did: no query data came back, result size could not
be varied. `not_applicable` means the run was never asked to look —
`detect_overfetching = false`, a single entry in `scale_factors` so payload
growth has one data point, or a detector whose subsystem is not in the build.

Collapsing `not_applicable` into `unavailable` would mark every endpoint
`inconclusive` for index analysis until `ExplainAnalyzer` ships, and would
turn every endpoint of a deliberately narrow run `inconclusive` for
pagination. Both are noise, not signal.

### Advisory classes never escalate

**Over-fetch is a hint that must never fail a build** (Part 3). It therefore
must not be able to force `inconclusive` either, which is a strictly stronger
statement than a hint — letting the weakest signal in the system veto the
clean verdict of every strong one inverts the ordering. An over-fetch gap is
reported and does not change state.

#### Admission rule — what may be added to the advisory list

The advisory list is a hazard as well as a mechanism. It exists for one
genuine case, and the foreseeable misuse is someone six months from now
adding a noisy class to it to quiet a report — laundering a real signal
through a mechanism built for an unfalsifiable one. So the bar is narrow and
stated here rather than left to judgement:

> A finding class may be advisory **only if its findings are inherently
> unfalsifiable from Loadwright's vantage point** — that is, the same
> observation is produced by correct code and by incorrect code, and nothing
> we can see distinguishes them.

Over-fetch qualifies. A table queried whose data never reaches the response
is produced just as readily by an authorization check, a filter, a derived
value, or a callback as it is by a wasteful eager load. From outside the
app there is no way to tell waste from correctness, so the signal cannot be
made falsifiable by better detection — only by information we do not have.

**"Noisy" and "low confidence" are explicitly not grounds.** A class that
produces false positives has a detection problem, and the fix is better
detection, a higher threshold, or narrower conditions — not exemption from
the state model. A class whose findings *could in principle* be confirmed or
refuted with data available to us is falsifiable, and belongs in the normal
derivation however imprecise it currently is.

Two consequences of admitting a class that follow from this:

- An advisory class must never contribute to a non-zero exit code either.
  Advisory status is about the whole class, not about the escalation path.
- Adding one is a documentation change here first. If the justification
  cannot be written in terms of unfalsifiability, the class does not qualify.

### Per-class coverage is reported regardless of state

Every endpoint carries its coverage, whatever its state:

```
checked: N+1 (pattern), pagination, over-fetch
not checked: index analysis (EXPLAIN not implemented in this version),
             latency percentiles
```

This is what makes the rule honest rather than merely tidy. It is more
informative than any single state label, and it means a reader can see reduced
coverage without `inconclusive` having to be overloaded to signal it.

Coverage is folded into `EndpointOutcome`, so reporting renders it rather than
recomputing it — and so the precedence above is stated once instead of being
rediscovered per format.

## Part 3 — Over-fetch detection

Compare the tables and columns touched by the SQL for a request against the
keys actually present in the serialized response. Tables queried whose data
never surfaces in the response suggest unused eager loading or wasted work
— the same class of problem Bullet's "unused eager loading" warning covers,
but confirmed against real output rather than inferred.

**This signal must be reported as a hint, never as a hard finding.** Data
is legitimately loaded without being serialized all the time — for
authorization checks, for filtering, for computing a derived value, for
callbacks. Phrase it as "loaded but not present in the response — worth
checking whether the eager load is needed," and never fail a build on it.
A tool that cries wolf about legitimate authorization queries gets
uninstalled.

## Part 4 — Payload growth → missing pagination

Track response body size against seeded scale factor. If bytes grow roughly
linearly with seeded rows, the endpoint is returning an unbounded
collection — the "unbounded query" problem, which no query-count signal
will ever surface because loading 10,000 records can be a single efficient
query. It's only visible in the response.

Flag when payload exceeds `config.max_response_bytes_warning` (default
1 MB) or when growth correlates with scale factor above
`config.payload_growth_correlation_threshold`.

## Part 5 — Serializer attribution

When an N+1 is detected, correlate the offending query's call stack against
the serializer/template layer (ActiveModel::Serializer, Jbuilder,
Blueprinter, `as_json` overrides). Serializer-level N+1s are the most
commonly missed kind in API apps precisely because the controller code
looks clean. If the stack points into a serializer, say so explicitly in
the finding — "N+1 originates in `PostSerializer#comments_count`" is
dramatically more actionable than a raw stack trace.

## Execution-mode note

Every signal in this document is **mode-independent**. Status codes, schema
validity, record counts, payload size, and queries-per-returned-record are
identical whether the request went through `ActionDispatch::Integration` or
a real socket — which is why `:in_process` is the right default for
answering "is this endpoint built correctly."

The one dependency: in `:http` mode, query counts arrive via the collector
middleware rather than direct instrumentation. If that middleware isn't
installed (remote target, app doesn't load the gem), queries-per-record and
over-fetch are unavailable, while the purely response-derived signals —
validity gate, payload growth, pagination detection — keep working. Report
the available subset rather than dropping the endpoint entirely.

## Testing requirements

- A spec proving a `403`-returning endpoint is marked `inconclusive` and
  never appears in the clean list or the summary rankings.
- A spec proving an endpoint returning `[]` while data was seeded is marked
  `inconclusive` with the "seeded data didn't match scope" reason.
- A spec with a fixture endpoint that is paginated *and* has an N+1,
  proving the returned-record-count slope catches it where the seeded-count
  slope does not. This is the regression test for the blind spot described
  in Part 2 — it's the reason this subsystem exists.
- A spec proving the two sweeps hold one axis fixed each — assert on the
  cells the engine actually generates, so a future change can't quietly
  reintroduce a combined matrix whose slope is unattributable.
- A spec proving a page-size sweep against a seed scale too small to fill
  the largest page is rejected or reported as not measurable, rather than
  producing a flat line that reads as healthy.
- A spec proving over-fetch findings are emitted as hints and never
  contribute to a non-zero exit code.
- A spec proving schema-invalid responses downgrade the result rather than
  being silently measured.
- A spec proving the worked case above: slope unmeasurable, pattern-match
  clean, endpoint `healthy`. And its converse — both N+1 detectors
  unavailable produces `inconclusive` naming the N+1 class.
- A spec proving an unmeasurable signal contributes NO finding, so the
  finding count cannot be inflated by missing coverage.
- A spec proving a `not_applicable` detector does not make a run incomplete,
  so an unshipped subsystem cannot mark every endpoint `inconclusive`.
- A spec proving an over-fetch gap never escalates to `inconclusive`.

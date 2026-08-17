# Comment pass — what was done, and what was deliberately left

Private working note. Gitignored; not part of the gem.

## The short version

The pass found much less to remove than expected. Measured before starting:

| | files | lines | comment lines | ratio |
|---|---:|---:|---:|---:|
| `lib/` | 74 | 16,390 | 3,835 | 23% |
| `spec/` | 81 | 15,024 | 1,997 | 13% |

23% in `lib` is on the heavy side, but a detector for **restatement comments**
(a comment that merely re-says what the next line of code does) found **zero**.
These are "why" comments, not "what" comments, and that is the distinction that
decides whether a comment earns its line.

Net change: **180 lines removed, 8 added, across 41 files.** Suite green
throughout (1387 examples).

## What was removed

**171 decorative rule lines** — `# =========` and `# ---------` separators that
contained no text. Every one wrapped a block whose content was kept in full.
Labelled separators (`# ------- collaborators`) were kept: those carry
navigation value.

The clearest win was `configuration.rb`, where 15 config sections were each
wrapped in a pair of rules. The ALL-CAPS section headers survive and the file
reads better without ~30 lines of rules between 93 settings.

**Three references to development sessions**, reframed rather than deleted.
"last session lost an afternoon to two files declaring `ASSIGNMENT`" carries a
real warning, but dates the code and means nothing to an outside reader. It now
reads "after two spec files declaring `ASSIGNMENT` with different regexes made
the drift spec pass or fail by seed" — same warning, no calendar.

**One doc-bookkeeping comment**, the only actual content removed. Original text,
preserved here because it is the one thing that is gone:

> ```ruby
> # CLAUDE.md section 2 corollary 7 requires a duration estimate with a
> # confirmation prompt above this threshold. It was specified there but
> # missing from configuration.md's template; added here and to the template.
> setting :long_run_confirmation_threshold_minutes, 10, section: :safety
> ```

That documents a discrepancy between two internal planning documents and the
fact that it was reconciled during development. It is bookkeeping about the
*documents*, not about the *code*, and it is worthless to anyone reading the
gem. Replaced with what the key actually does:

> ```ruby
> # A run longer than this prints its estimate and asks before starting, so nobody
> # discovers a four-hour sweep by waiting through it.
> ```

## What was deliberately left, and why

**The long class-level blocks.** There are 39 comment blocks of 18+ lines in
`lib`. They were sampled rather than trimmed on sight, and they are dense. The
36-line header on `ResourceGuard` states the governing principle (retreat, never
resolve), why the class exists before the load engine, the structural
breaker/guard split, and the two carve-outs that stop a real endpoint defect
disappearing into "the database was busy". Every paragraph carries distinct,
non-obvious information. Cutting it would make the gem worse, not cleaner.

**105 citations of internal design documents** in `lib` — `production-safety.md`,
`resource-contention.md`, `CLAUDE.md section 2`, and so on. Those documents are
not published. Left in place because:

- every citation is a parenthetical next to the rule itself, which is always
  stated in full, so the comment reads fine to someone who cannot open the file;
- they are provenance — they say a decision was made deliberately and where it
  was argued — which is worth more than the cost of an unresolvable filename;
- rewriting ~105 of them mechanically risks mangling carefully-written rationale
  to fix something cosmetic.

The README's Contributing section explains the convention instead, so nobody
goes hunting for files that are not there.

**Duplicated comment text across `lib` and `spec`.** 23 long comment lines appear
more than once, almost all of them a spec restating the rule it exists to
enforce. That is the spec doing its job. The three copies of "FIXTURE. The flaws
here are load bearing — do not fix them." in `examples/sample_app` are likewise
intentional: each controller needs the warning on its own.

## If a future pass wants to go further

The only remaining lever of any size is the 105 design-doc citations. Stripping
the filenames while keeping the surrounding rationale would read slightly
cleaner to an outside contributor and would cost the provenance. It is a
judgement call, not a defect, and it should be made deliberately rather than as
a side effect of a tidy-up.


---

# Session notes — write path, auth, suggestions, GraphQL

Rationale trimmed out of source comments to keep them lean, kept here so it is not
lost. Nothing below is needed to *use* the gem; it is why the code looks like it does.

## Two bugs that mattered more than the features they were found under

**`IdentityPool#resolve!` was called from nowhere in `lib/`.** A configured
`auth_token_provider` produced a pool whose tokens were never resolved, so every
request went out unauthenticated and the report told the user their token was
misconfigured. That is the failure `AGENTS.md` marks VERY_HIGH probability and
"most common first-run failure" — self-inflicted, which is a decent explanation for
why it was so common.

Two independent gaps let it survive, and both had to close: nothing called it, and
no fixture endpoint checked a token, so an end-to-end run could not tell an
authenticated request from an anonymous one. `sample_app` now has `/api/v1/me`.
The lesson generalises: a unit-tested collaborator with no caller is invisible to
both layers of the suite.

**GraphQL errors read as healthy.** `{"errors":[...]}` with `data: null` and HTTP
200 passed the validity gate — reachable before any GraphQL support existed, by
anyone who recorded GraphQL request specs. The check is deliberately narrow (a
top-level `errors` ARRAY whose entries are objects carrying `message`) so a REST
payload with an "errors" key is untouched, and `data` is deliberately *not* required
alongside, because a query that fails before execution returns errors and no data —
which is the case most worth catching.

## Why the write path reuses the watermark

Cleanup already swept rows above a pre-seed high-water mark in tables that received
an INSERT; it simply never learned about tables the *requests* wrote to. Feeding it
those table names was the whole feature. The names come off query fingerprints the
runner already collects — normalisation keeps table names while discarding values —
so it works in both transports with no new plumbing, including `:http`, where the
query data has already crossed the collection endpoint from the app's process.

An earlier config comment said "turn this off on a shared database", which promises
more than the flag delivers: a table the factories also wrote to is swept above the
watermark either way, and always was. The flag narrows the sweep; `:leave` is what
cleans up nothing. A spec pins that distinction because the generous reading is the
natural one.

## Why fix suggestions refuse to guess

They read a normalised query shape and know nothing about the surrounding code. So
an unrecognised shape returns nil rather than a plausible-looking suggestion: this
is the part of a report a reader is most likely to act on without checking, and
being wrong here would cost the *finding* its credibility too, not just the advice.

The COUNT case is the one to defend. Almost all N+1 advice says "add `includes`",
and for a repeated COUNT that is wrong — preloading still counts with a query unless
the code stops calling `.count`. The suggestion says so outright. A future
maintainer "simplifying" it back to `includes` would reintroduce the most common
piece of wrong advice about N+1s.

## GraphQL: three protocol facts that drove every decision

1. **One path, one verb, N operations.** So `(path, verb)` — which identifies a REST
   endpoint perfectly — collapses an API into one row. The operation name is carried
   separately from `path` so that nothing reasoning about paths (`excluded_paths`,
   path params, the resource name) starts seeing an operation name where it expects
   a URL.

2. **A `query` is a read that travels by POST.** Verb-based classification marked an
   entire GraphQL API as mutating, making `allow_mutating_requests` — a safety opt-in
   for endpoints that *write* — a prerequisite for measuring reads. That is worse
   than useless: it teaches people to switch on real write traffic to test reads.

3. **The page size is a variable inside the document.** None of the REST page-size
   machinery reaches it. An operation that hardcodes `first: 10` is reported as
   unsweepable rather than measured three times at the same size — a flat line from
   an unvaried page is indistinguishable from a genuinely flat query count, and
   reporting it as healthy is the exact false all-clear the tool exists to avoid.

Record counting for GraphQL descends `data` and takes the first field that yields a
collection: a plain Array, or `edges`/`nodes` on a Relay connection. A connection
object is one Hash however many records it holds, so counting the field itself would
have reported 1 for every page size and produced a perfectly flat, perfectly wrong
slope.

The fixture is deliberately *not* graphql-ruby. Taking that dependency to prove
Loadwright can drive a GraphQL endpoint would be testing someone else's gem; what
matters is the protocol shape, and all of it fits in one small controller.

## Spec-writing traps hit twice this session

Both surfaced as failures and were fixed, but they are easy to write and easy to
miss:

- **Asserting on an outcome state that is `inconclusive` for an unrelated reason.**
  An auth spec at 4 requests per cell is inconclusive for *sample size* — p50 needs
  20 — whatever the auth did. The assertion moved to response statuses, which is the
  thing actually being claimed.
- **A helper that resets the database after the test created its fixture row.**
  The "pre-existing row survives cleanup" spec created a survivor, then called a
  helper whose first act was `reset_sample_app!`. It failed for the right-looking
  wrong reason.


## Per-resolver attribution — why graphql-ruby became a dev dependency

The protocol fixture deliberately avoided graphql-ruby: proving Loadwright can POST
a document and read a response is about the protocol shape, and taking the
dependency to demonstrate that would be testing someone else's gem.

Attribution is a different situation and the earlier reasoning does not carry over.
It integrates with graphql-ruby's tracing API (`execute_field` /
`execute_field_lazy`), and an integration verified against a hand-rolled stand-in
only proves the stand-in works. So `graphql` is a DEV dependency and there is a
real schema in `sample_app`. It is not a runtime dependency: the tracer is a plain
module a host schema opts into with `trace_with`.

Two details worth keeping:

- **`field.owner.graphql_name` + `field.graphql_name`, not `query.path`.** The
  response path includes list indices (`authors.0.postCount`), which differs per
  record and would make every repeated query look distinct — destroying the
  duplicate detection the finding depends on.
- **`execute_field_lazy` is traced too.** Lazy fields resolve after their enclosing
  frame has unwound, which is exactly where a batched loader does its work. Without
  it those queries land on whatever happened to be on the stack.

The control that matters in the spec is the *second* operation, whose N+1 is in a
different resolver. Without it, attribution could be returning one constant and
still pass.

## A transport inconsistency the GraphQL work exposed

`:http` JSON-encoded a structured body and set the content type; `:in_process`
passed it to ActionDispatch as `params:`, which form-encodes and stringifies every
value. So the two modes sent *different content types for the same request*.

Invisible for most REST params, because Rails coerces them anyway — and fatal for
GraphQL, where `Int!` rejects `"3"`. Fixed by sending `as: :json` in-process when
the body is structured. Worth remembering as a class of bug: the Null and InProcess
transports are convenient, and convenience is exactly what lets them drift from the
one that talks to a real socket.

Both refinements are right, and I'd have wanted them even if I'd thought to
specify them. Keeping both. Four follow-ups, then session 03.

## On the two judgment calls

**Three detector states — accepted, and the distinction is load-bearing.**
The line you drew is the correct one: who prevented the answer, the app and
its data or a run that was never asked to look. Collapsing them would have
marked every endpoint `inconclusive` for index analysis until EXPLAIN ships,
which makes the state useless during exactly the period it's most needed.
And `scale_factors: [1]` being user choice, equivalent to
`detect_overfetching = false`, is the right read.

**Over-fetch as advisory — accepted, and you're right that it contradicts
the doc otherwise.** "The weakest signal would veto every strong one's clean
verdict" is the argument. `inconclusive` is a *stronger* claim than a
finding, so a class explicitly barred from failing a build cannot coherently
force it. Don't change `ADVISORY_CLASSES` back.

The over-fetch coverage bug is the best thing in this report. Reading the
table list from duplicate fingerprints meant a clean endpoint looked
unqueried and therefore uncovered — the healthiest endpoints would have gone
`inconclusive`. That's precisely the inverted-signal failure the three-state
model exists to prevent, found by implementing the model. Worth a regression
spec named for what it was, so nobody "simplifies" it back later.

## Four follow-ups

**1. `ADVISORY_CLASSES` needs a documented admission rule.** Right now it
has one member and an obvious rationale. The risk is six months out, when
someone adds a noisy class to it to quiet a report — laundering a real
signal through a mechanism built for a genuinely advisory one. Write the
rule into `response-analysis.md`: a class is advisory only if its findings
are inherently unfalsifiable from our vantage point — over-fetch qualifies
because authorization and filtering queries legitimately produce it, so we
cannot distinguish waste from correctness. "Noisy" or "low confidence" is
not sufficient grounds; those get better detection, not advisory status.

**2. Secret file lifecycle under hard kill.** `Lifecycle` teardown covers
SIGINT and normal exit, but `SIGKILL` can't be trapped, so a stale
mode-0600 secret can outlive its run. Put it in a per-run directory created
with `Dir.mktmpdir` at 0700 — which also closes the symlink race that
writing a predictable path into a shared temp dir would open — include the
run id in the filename, and have the reader reject a secret whose run id
doesn't match the current run. A leftover secret should be inert, not merely
unlikely to be found.

**3. Mutation-audit methodology.** Your no-op mutation on Layer 1b adjacency
is the failure mode of hand-rolled mutation testing, and you caught it by
noticing rather than by construction. Make it structural: before running the
spec, assert the mutation actually changed the observable return value. A
mutation that doesn't change behaviour proves nothing about the spec, and
next time it may not be obvious.

**4. Propagate the three detector states to `AGENTS.md` §9.1.** The
`state_derivation` block from 02c encodes two detector states, not three. An
agent reading it will conflate "you turned this off" with "we tried and
couldn't" — and those warrant completely different advice to a user. Add
`not_applicable` alongside `unavailable`, with the who-prevented-the-answer
line as the discriminator, plus a note that advisory classes never escalate
to `inconclusive`. Still nothing else in that file, and leave the
`STATUS: SPECIFICATION_ONLY` marker.

## On `spec:seeds` catching your own order-dependent example

That's the task working as intended, and worth noting for later: the fence
example omitting `rails_env` on purpose is a legitimate test design that
happened to be environment-sensitive. `hide_const` is the right fix. Second
catch in two outings — keep it in the default local workflow, not just CI.

## Next

Session 03 as planned — reporting stays untouched until performance signals
and run history are in. I've added a note to the top of the 03 prompt about
the detector-activation transition: shipping `ExplainAnalyzer` and
`Statistics` flips `index_scan` and `latency` from `not_applicable` to live,
so run the fixture sweep before and after and diff the state distribution.
`healthy` → `has_findings` is the detectors working; a mass migration to
`inconclusive` means a wiring bug, and I'd rather that be caught by an
expected diff than discovered in a report template.

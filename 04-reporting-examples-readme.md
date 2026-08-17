Continuing work on Loadwright. Re-read CLAUDE.md (especially section 6 so
you know what's already built) and
`.claude/skills/loadwright-development/SKILL.md` before starting. This
session is reporting and documentation — the parts a user actually sees.

1. **Reporting** (`references/reporting.md`). HTML first, since it's the
   primary deliverable. Self-contained single file — inline CSS/JS, no CDN
   dependency, so it works offline and survives being emailed to someone.
   Then Markdown and JSON from the same underlying run-result structure;
   don't let formatting logic leak back into the collection code.

   Non-negotiables from the reference docs, because they're easy to lose
   at the rendering layer:
    - **Reporting must not branch on `config.execution_mode`.** It renders
      from `CapabilityProfile` and `Measurement`. The one annotated exception
      is the metadata header's display read — the grep spec allows exactly
      that and nothing more.
    - **Capability is rendered per-window, not as one global claim.**
      `CapabilityProfile` records mid-run downgrades, so a report may
      legitimately say a signal was available for the first 200 requests and
      unavailable after, with the downgrade event and its cause shown. A
      single "this mode supports X" banner would be a lie in any degraded
      run — which is the case the whole three-seam design exists to get
      right.
    - **`Measurement.unavailable(reason)` renders the reason**, never a blank
      cell, a dash, or a zero. The reason is the actionable part.
    - Execution mode and transport/collector pairing stated in the metadata
      header.
    - The time breakdown rendered as a stacked view — an endpoint that's
      80% serialization must not read as a database problem.
    - Percentiles shown with their sample counts, and omitted entirely
      where the sample size can't support them.
    - Three endpoint states, visually distinct: healthy / has findings /
      **inconclusive**. An endpoint we couldn't validly measure must never
      render like one that passed.
    - Every safety decision, containment measure, backoff event, step-down,
      and quarantine appears in the report — a reader should be able to
      answer "was this run safe, and is this data trustworthy?" from the
      report alone, without the terminal scrollback.
    - A cell that ran at reduced concurrency after a step-down must say so
      rather than displaying the requested level.
    - A run that aborts partway still writes a partial report, clearly
      marked partial.

   Generate a real report from a full run against `examples/sample_app/`
   and open it in a browser before calling this done. The sample app has a
   deliberate N+1, an unpaginated endpoint, an over-fetching endpoint, and
   a 403 endpoint — all four should be clearly legible in the output, and
   the 403 one should be `inconclusive`, not "fast." If any of them is
   hard to spot in the rendered report, the report design isn't finished.

2. **The comparison report** (`references/run-comparison.md`) — new
   findings, resolved findings, within-noise changes shown separately from
   regressions, and state transitions surfaced explicitly. Generate a real
   one by running the sample app twice with a deliberate regression
   introduced between runs, and check that the regression is the first
   thing you see.

3. **The full `examples/` set** — 11 directories per
   `references/readme-and-examples.md`, including `http_mode/`.
   Each subdirectory gets a complete, commented, copy-pasteable
   initializer plus a short README explaining who it's for and what it
   trades away. These double as integration-test fixtures — wire them into
   the test suite so a config key rename can't silently invalidate them.

4. **The README** (`references/readme-and-examples.md` has the full
   section order). Two things I care about most:
    - **Safety comes before installation**, not in a section near the
      bottom. Someone deciding whether to point a load generator at their
      own database should hit the environment gate, dry-run default, and
      the "what this will never do" list before they're invited to
      `bundle add` anything.
    - **The "when not to use this" section is honest.** Point people to
      n_plus_one_control for CI gating, Bullet/Prosopite for continuous
      dev-time detection, an APM for production reality, k6/vegeta for
      capacity planning. A README that only sells is less trustworthy than
      one that draws the boundary.

   Use the real report you generated in step 1 for the screenshots and
   walkthrough — no invented output.

5. **`AGENTS.md`** (`references/readme-and-examples.md`, AGENTS.md
   section). A draft exists at the repo root — verify every command, config
   key, CLI flag, report state, and diagnostic against what actually got
   built. Remove the `STATUS: SPECIFICATION_ONLY` marker only once verified
   end to end.

   Known-stale items to check specifically, since these were written before
   the session-01 decisions and several are now wrong rather than merely
   incomplete:

    - **`DIAG-10` and §12 `critical_interaction`** — both tell an agent to
      raise `max_error_rate_before_abort`. The structural breaker/guard split
      eliminated that workaround, and following the old advice loosens a
      safety threshold for no reason. Session 02 should already have fixed
      these; confirm rather than assume.
    - **§5.1 capability matrix is keyed by execution mode.** Capability is a
      property of the *collector*, so the matrix needs restructuring around
      transport + collector pairings — the `yes*` footnotes were already
      gesturing at this. The degraded-remote row (`HttpTransport` +
      `External` collector) is the one that matters most and is currently
      implicit.
    - **Rails floor** — now `>= 7.0`. `AGENTS.md` states no floor at all.
    - **`load_async` / spawned-thread under-attribution** — add as a
      documented known gap. An agent reading only the capability matrix
      would otherwise report those query counts as trustworthy.
    - **`Measurement` semantics** — agents need to know that an unavailable
      signal carries a reason and is not zero, since misreading that is
      exactly the confidently-wrong-summary failure the invariants exist to
      prevent. Worth its own invariant.
    - **New diagnostics** for the cases the three-seam design created:
      degraded collector mid-run, and capability differing between windows of
      the same run.

   Do not rewrite it into readable prose. The dense YAML-ish blocks,
   decision trees, and symptom→fix tables are deliberate — they remove the
   inference step that makes agents apply operational rules
   inconsistently. Human legibility is explicitly not a goal for that file.

   Also add the "For AI Agents" block to the README pointing at it, near
   the top rather than in an appendix.

6. **The documentation-drift spec** — activate the README half. The
   three-way check (initializer ↔ `Configuration` ↔ `AGENTS.md`) has been
   live since session 02; this session wires in README. Mind the directional
   rules, since getting them wrong makes the spec either useless or
   permanently red: **equality** for initializer ↔ `Configuration` and
   README ↔ `Configuration`, **subset only** for `AGENTS.md` (every key it
   mentions must exist; the reverse does not hold, because `AGENTS.md`
   documents task-relevant keys rather than all of them).

   The README half was left as a self-deactivating skip, not a `pending`
   example — so adding the README's configuration walkthrough should turn
   the suite red until the assertion is connected. If it doesn't, the skip
   condition is wrong and that's worth fixing before proceeding. I'd rather a future change break a test than have the
   docs quietly start lying.

7. Update CLAUDE.md section 6, and give me a summary at the end of what's
   done, what the test suite covers now, and anything you'd flag as
   still-rough before this could be published as a real gem.
---

# SESSION CONTINUATION — where this was left

> Appended at the end of a working session, mid-phase. Items 1, 2 and 3 above are
> **done**; items 4, 5, 6 and 7 are **not started**. Start at "What to do next".

Suite: **1316 examples, 0 failures, 2 pending**, green across all 5 seeds
(`bundle exec rake spec:seeds`). Mutation audit green at 26/26. Working tree clean.

## What landed

- **Reporting** — `HtmlReport`, `MarkdownReport`, `JsonReport`, all rendering through a
  shared `Reporting::Presenter`. Capability renders per window with the cause of each
  downgrade; unavailable measurements render their reason; the three states are
  visually distinct and inconclusive sorts above healthy; an aborted run is marked
  partial above the fold.
- **`ComparisonReport`** — Markdown and HTML. A refusal renders *nothing else*. State
  changes come before "Resolved" so an endpoint that became unmeasurable is not read
  as a fix. The CLI renders through it rather than its own printer.
- **The examples set** — all ten initializers plus READMEs, replacing the
  placeholders, with `spec/loadwright/examples_spec.rb` evaluating each one the way a
  host app does and asserting every key it sets still exists.
- **`spec/loadwright/interrupt_end_to_end_spec.rb`** — the folded-in coverage seam: a
  real SIGINT during a real `:http` run, proving server teardown, row cleanup, the
  partial-report callback, and a partial result that renders as partial.
- **`examples/sample_app` now requires ActiveJob and ActionMailer** (both added to the
  Gemfile), so containment is exercised for real rather than disabled in every
  end-to-end run.

## Bugs found and fixed, because the work was driven by real output

Recorded because each is a *class* of mistake worth watching for, not a one-off:

1. **The concurrency-1 request loop ignored interrupts.** Only the threaded path
   checked. Concurrency 1 is the default and is forced under `:in_process`, so Ctrl-C
   did not stop the loop until the cell finished — and with the server already torn
   down, the resulting connection errors tripped the circuit breaker. The run then
   reported itself aborted at a 20.1% error rate rather than interrupted: a false
   account that blames the app for the user pressing Ctrl-C.
2. **Every completed run wrote a phantom second history record** marked "interrupted",
   which then appeared in `runs list` and made every comparison warn that a healthy
   run had been aborted. Fixed by a contract: the *runner* persists its own result;
   the Lifecycle-armed hook covers only `#run` never returning.
3. **`%w[Signal Status Why not]`** — four headers for three columns, which renders as a
   ragged table in Markdown. There is now a spec checking every table's header count.
4. **A 0.26ms latency move reported as a 40% regression.** Percentages on
   sub-millisecond values are jitter wearing a decimal point, and local endpoints live
   in that range. Latency deltas now need an absolute floor as well as a relative one.
5. **`ASSIGNMENT` declared at the top level of two spec files** with different regexes.
   A constant assigned inside `RSpec.describe` lands on Object, so they overwrote each
   other and the drift spec passed or failed by seed. `architecture_spec` now guards
   the whole class.

**The pattern worth carrying forward:** four of these five were invisible to unit
specs and surfaced only from generating a real report, running a real regression, or
sending a real signal. Keep doing that for the README walkthrough — use the real
generated output, not invented output.

## What to do next

**Item 4 — the README.** Nothing is written yet (`README.md` is still the stub
pointing at CLAUDE.md). This gates item 6.

**Item 6 — activate the drift spec's README half.** The self-arming skip is at
`spec/loadwright/documentation_drift_spec.rb:120`, keyed on the README growing a
heading matching `/configuration/i`. Adding the walkthrough should turn the suite red
until the assertion is connected. **If it does not, the skip condition is wrong and
that is worth fixing before proceeding.**

**Item 5 — verify `AGENTS.md` end to end.** The six known-stale items are listed
above; §5.1's capability matrix keyed by execution mode is the important one, since
capability belongs to the collector. Sections added during sessions 02–03 that need
checking against the implementation: `INV-11` scope note, `DIAG-10e`, `§7b` comparison
rules, `COMP-01`–`COMP-04`. Remove `STATUS: SPECIFICATION_ONLY` only once verified.

**Item 7 — CLAUDE.md section 6.** Currently says reporting is what remains, which is
no longer true.

## Still-rough, flagged for triage rather than assumed

- **`loadwright run` and `record` are still stubs** (`lib/loadwright/cli.rb:89`).
  Everything they would orchestrate now exists — safety guard, containment, discovery,
  seeding, engine, analysis, reporting, history — so this is wiring rather than
  design. But **the gem cannot currently be driven end-to-end from the CLI**, which is
  the single biggest gap between "the pieces work" and "someone can use this". Worth
  doing before the README, since the README's quickstart has to show real commands
  producing real output.
- **`Comparator::SIGNAL_REQUIREMENTS` maps only `queries`** to a capability. Allocation
  and payload deltas are compared unconditionally, and `clean_memory_attribution` has
  no consumer at all — so a run that could not attribute memory cleanly still has its
  allocation figures compared as though it could.
- **`resolved_findings` vs `changed_findings`** is not specced for the three-way case:
  a finding whose kind persists but whose detail changes lands only in "changed",
  which is believed right but untested.
- **Mutating endpoints confounding their own measurement** is documented in
  `AGENTS.md` and disclosed in the report, but not *detected*. `performance-signals.md`
  Part 6 wants either per-cell state reset or an explicit confound flag.
- **The sample app's `other` bucket is ~90% of request time.** Honest for a fixture
  this trivial (middleware and controller Ruby dominate), but it means the time
  breakdown's *interesting* case — an endpoint dominated by serialisation — has no
  live fixture. Consider adding a deliberately serialiser-heavy endpoint.

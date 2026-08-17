# README & Example Setups — Design Reference

> **Status: specification for software that does not exist yet.** Nothing
> described in this document has been built. Every statement here defines
> *intended* behavior, not current behavior — read it as a build order, not
> as documentation of a working system. When implementation diverges from
> this document, update the document in the same commit.


Adoption is a feature. A developer evaluating this gem is deciding whether
to point a load-generating tool at their own database — the README is where
they decide whether to trust it. Treat it as a first-class deliverable, not
documentation debt to clean up later.

## README structure (in this order — the order matters)

1. **One-sentence description**, then a 3–4 sentence "what problem this
   solves" that names the alternatives honestly (Bullet, Prosopite,
   n_plus_one_control, APM tools) and says where this fits between them.

2. **Safety, immediately — before installation.** Not buried in a section
   near the bottom. A reader must encounter the environment gate, the
   dry-run default, the mutating-request opt-in, and the "never runs in
   production without four explicit steps" guarantee *before* they're
   invited to install anything. Include a short "what this tool will never
   do" list: never kills database sessions, never truncates tables, never
   sends real email/jobs/HTTP by default.

3. **60-second quickstart** — install, generate initializer, run against
   one endpoint with `--dry-run`, then for real. Show the actual terminal
   output and a screenshot/excerpt of the resulting report. Someone should
   be able to see what they get before committing to full setup.

4. **"For AI Agents" block.** A short, prominent, clearly-headed section
   near the top — after the quickstart, before installation detail —
   pointing at `AGENTS.md` in the repo root. Purpose: an agent scanning the
   README should find its own entry point within the first screen, without
   reading human-oriented prose first. Keep it to roughly this shape:

   ```markdown
   ## For AI Agents

   If you are an AI agent helping someone configure, run, or interpret
   Loadwright, start at [`AGENTS.md`](AGENTS.md) in the repository root.

   It is a dense, machine-oriented operational reference covering setup
   procedure, a configuration cookbook keyed by task, a symptom-to-fix
   diagnostic table, report interpretation rules, safety invariants you
   must not violate, and known agent antipatterns. It is written for
   machine consumption and is not intended to be pleasant human reading.

   Humans should keep reading this README instead.
   ```

   Do not bury this in a docs/ subdirectory or an appendix. Root-level
   `AGENTS.md` plus a top-of-README pointer is the convention agents are
   most likely to find without being told.

5. **Installation**, including the `:development, :test` Gemfile group
   (with a sentence on *why* — it's what makes the `if defined?` guard in
   the initializer necessary).

6. **Configuration walkthrough**, section by section, mirroring the
   initializer's own grouping. Every key documented with its default and
   what changing it does. Link out to the deeper contention-tuning table
   rather than inlining all of it.

7. **Choosing an execution mode** — this is the first real decision a
   user makes, and it belongs early. Frame it the way
   `execution-modes.md` does: `:in_process` (the default) finds
   query-structure problems with zero setup; `:http` finds capacity
   problems with real server concurrency. Include the scenario table, and
   be explicit that the default is not a lesser mode — it's the right one
   for most questions most of the time. Also state plainly which findings
   are unavailable in each mode, so nobody reads an absent finding as a
   clean bill of health.

8. **Discovery modes** — the three sources (OpenAPI, integration-spec
   recording, route fallback), what each gives you, and the merge
   precedence. Be explicit that recording requires running your specs
   once, and what that costs.

9. **FactoryBot setup** — the `factory_map`, traits, why your factories
   need `sequence` for unique fields, and what the collision error looks
   like when they don't.

10. **Running it** — CLI flags, rake tasks, the dry-run/execute split,
   filtering to a subset of endpoints (the common case for a large app is
   "just test these three routes," and that should be easy to find).

11. **Reading the report** — walk through each section with a real example.
   Explain the three endpoint states (**healthy / has findings /
   inconclusive**) and why `inconclusive` exists, since that concept is
   unique to this tool and will otherwise confuse people.

12. **Tuning contention handling** — the table from
    `resource-contention.md`, the three presets, and the
    error-rate-vs-contention interaction warning.

13. **Troubleshooting table** — symptom → likely cause → fix. Seed the
    table with at least: run aborts immediately (baseline health check /
    environment gate), every endpoint `inconclusive` (auth not configured),
    empty responses (factories don't match endpoint scope), production
    boot fails (missing `if defined?` guard), runs take forever (backoff
    budget misconfigured), no N+1 detected on an endpoint you know is bad
    (pagination blind spot — see `response-analysis.md`).

14. **When *not* to use this** — honest comparison. CI gating →
    `n_plus_one_control`. Continuous dev-time detection → Bullet or
    Prosopite. Production reality → an APM. Capacity planning → k6/vegeta.
    A README that only says "use my thing" is less trustworthy than one
    that draws the boundary.

15. **FAQ, contributing, license.**

Keep code examples copy-pasteable and real — no `# ...` elisions in
anything a reader is meant to run.

## Example setups the gem ships

An `examples/` directory at the repo root, each subdirectory containing a
complete, commented `loadwright.rb` initializer plus a short `README.md`
explaining who it's for and what tradeoffs it makes. These double as
integration-test fixtures, so they must stay valid.

| Example | Demonstrates |
|---|---|
| `minimal/` | Smallest working config — routes-only discovery, no factories, GET-only, defaults everywhere |
| `openapi_driven/` | Full OpenAPI/Swagger setup, including schema validation of responses |
| `integration_spec_driven/` | Recording mode against existing request specs, for apps with no OpenAPI doc |
| `factory_heavy/` | Complex `factory_map` — traits, associations, nested resources, a factory needing `sequence` |
| `paginated_api/` | Page-size sweep config, the case where seeded-scale slope alone misses the N+1 |
| `http_mode/` | `:http` execution — booting Puma, real concurrency, pool-vs-threads findings |
| `shared_dev_database/` | The `:conservative` contention preset, for teams sharing a dev DB |
| `mysql/` | Non-Postgres setup and what degrades gracefully (lock introspection, pg_stat_statements) |
| `large_monolith/` | Path filtering and subset runs for an app with hundreds of endpoints |
| `mutating_endpoints/` | The `allow_mutating_requests` opt-in with side-effect containment, and the risks |
| `sample_app/` | A minimal Rails API app used by the gem's own end-to-end tests — deliberately contains one N+1, one unpaginated endpoint, one over-fetching endpoint, and one endpoint that 403s, so every analysis path has a live fixture |

`sample_app/` is the most valuable of these and should be built early — it
gives the gem's own test suite something real to run against, and gives
the README screenshots something honest to show.

## AGENTS.md — the agent-facing operational reference

Ships at the **repo root**, alongside the README. It is written for machine
consumption: dense YAML-ish blocks, decision trees, symptom→fix tables, and
numbered invariants rather than prose. Human legibility is explicitly not a
goal, and it should not be "cleaned up" into readable documentation.

Required sections (a draft already exists at `AGENTS.md` — keep it in sync
as implementation lands rather than rewriting it):

- **Invariants** — numbered, absolute rules an agent must never violate
  (never enable `allow_production` on a user's behalf, never remove the
  `if defined?` guard, never report `inconclusive` as healthy, never
  suggest killing DB sessions, etc.)
- **Request router** — user intent → section, so an agent can jump
  directly rather than reading linearly
- **Setup procedure** — ordered, with exact commands and verification steps
- **Mode selection decision tree** and a capability matrix stating which
  findings are measurable in which execution mode
- **Configuration cookbook** — keyed by task, with exact keys and the
  reasoning behind each
- **Diagnostic table** — symptom → probability → cause → fix, covering the
  known first-run failure modes. This is the highest-value section.
- **Report interpretation rules**, including the three-state model and the
  caveats an agent must always include in a summary
- **Agent antipatterns** — the specific mistakes agents make with this
  gem, stated as wrong/right pairs
- **Escalation list** — what to stop and ask a human about
- **Canned safety answers** for the questions users reliably ask

Why this exists separately from the README: an agent reading
human-oriented prose has to infer operational rules from explanation, and
it infers them inconsistently. Stating them as explicit invariants and
lookup tables removes the inference step. The antipattern and invariant
sections in particular exist because a confidently-wrong agent summary
(e.g. "18 endpoints healthy" when 12 were inconclusive) does more damage
than no summary at all.

## Documentation-drift guard

The config keys documented in the README, the keys documented in
`AGENTS.md`, the keys in the generated initializer, and the attributes on
`Loadwright::Configuration` must not drift apart.

**The assertion direction differs per source**, and getting it wrong makes
the spec either useless or permanently red:

| Sources | Direction | Why |
|---|---|---|
| initializer ↔ `Configuration` | **equality** | The generated file is meant to be exhaustive, so every key appears in both. |
| README ↔ `Configuration` | **equality** | The configuration walkthrough documents every key with its default. |
| `AGENTS.md` → `Configuration` | **subset, one direction only** | Every key `AGENTS.md` names must *exist*. The reverse is deliberately not asserted. |

The one-directional rule for `AGENTS.md` matters. It legitimately documents
only task-relevant keys, not all ~92 — asserting the reverse direction would
force it to become an exhaustive key reference, which is the README's job
and would wreck the cookbook's usefulness.

**The failure this catches is phantom keys.** An agent setting
`config.some_renamed_key = true` gets no error, no warning, and no effect —
the setting silently does nothing and the agent reports success. A stale
agent reference is worse than a stale human one, because an agent acts on
it confidently without the skepticism a human reader applies.

### Phasing

Three of the four sources can be checked from the first scaffold —
`AGENTS.md` already exists in full, and only the README is a stub. Leaving
the agent reference unchecked through several sessions of active config-key
churn is precisely backwards given the reasoning above.

The README half must **not** be deferred with a `pending`/`skip` example.
A pending example is invisible: it reads green for months and nobody
notices it never activated, which is exactly the drift it was meant to
guard against. Make the deferral self-arming instead — detect whether the
README has a configuration section yet, skip only while it genuinely
doesn't, and fail the moment the README gains one without the assertion
being wired up. The end state is that the session adding the README's
configuration walkthrough cannot do so without the spec going red until it
is connected.

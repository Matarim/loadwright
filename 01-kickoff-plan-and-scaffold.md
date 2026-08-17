This is a greenfield project — the repo currently contains planning
documents and nothing else. No gem, no lib/, no specs, no Gemfile. Assume
nothing exists until you've checked.

I want to start a new Ruby gem called Loadwright (rename freely if you have
a better name — nothing downstream depends on it) in this directory. I've
already added CLAUDE.md and .claude/skills/loadwright-development/ (with a
SKILL.md and ten reference files under references/) to this repo, plus an
`AGENTS.md` draft at the root — read all of them before doing anything
else. They are the spec for this
project; don't re-derive the design from scratch or from this prompt alone.

For context on what it's for, in one paragraph: it's a local developer
diagnostic gem for Rails APIs that discovers endpoints from an OpenAPI doc
and/or the app's own integration specs, seeds realistic data through the
app's FactoryBot factories at increasing scale, hits every endpoint under a
scale × concurrency matrix, watches for N+1 queries / slow SQL / memory
bloat / connection pool pressure, and produces a single readable report.
Production safety is the single most important property of this tool —
read production-safety.md closely, it is not optional detail.

For this session, I do NOT want you to implement the full gem yet. I want:

1. **A plan, shown to me before you write any code.** Read CLAUDE.md's
   build order (safety guard → containment → config DSL → execution layer
   → discovery → seeding → instrumentation → resource guard → load engine
   → response analysis → performance signals → run comparison → reporting
   → README/examples) and turn it into concrete milestones — what files
   get created in what order, roughly how you'll test each one, and where
   you expect the trickiest parts to be (I'd guess: the `:http` mode
   request-ID correlation without cross-request metric bleed, the
   integration-spec recording mechanism, and measuring N+1 slope correctly
   on paginated endpoints — but tell me if you disagree based on what you
   read). Stop and let me react to this plan before moving to step 2.

   One thing I specifically want your read on before we start: the two
   execution modes in `references/execution-modes.md` share an analysis
   pipeline but collect metrics completely differently. Tell me whether
   you think the driver abstraction there is right, or whether you'd
   structure the seam between "how requests are issued" and "how metrics
   come back" differently.

2. **After I confirm the plan, scaffold the gem structure** — but
   structure only, not feature implementation:
   - Standard gem layout (`bundle gem loadwright` conventions), gemspec
     with a sensible dependency list (don't pin versions speculatively —
     use conservative version constraints and explain any dependency
     you're adding and why)
   - The `lib/loadwright/` directory tree as laid out in CLAUDE.md section
     3, with empty or stub classes/modules for each subsystem (enough to
     `require` cleanly and have RSpec find them, not full implementations)
   - RSpec set up for the gem's own test suite, with a spec file stub per
     subsystem
   - The Rails generator skeleton for `rails generate loadwright:install`
     that will eventually write `config/initializers/loadwright.rb` from
     the template in `references/configuration.md` (stub the generator,
     don't fill in the full template yet — that's the next session)
   - A README stub that just points to CLAUDE.md for now rather than
     duplicating it (the real README comes last, per
     `references/readme-and-examples.md`)
   - An `examples/` directory with the subdirectories listed in
     `readme-and-examples.md`, each holding a placeholder README noting
     what it will demonstrate — empty for now, but the structure should
     exist so it doesn't get forgotten
   - Leave `AGENTS.md` at the repo root where it is. It's a
     specification-stage draft for agents helping users adopt the gem, and
     it gets verified against the implementation in the final session — not
     now. Don't edit or "clean up" its formatting; the density is
     deliberate.

3. **Update CLAUDE.md's status checklist (section 6)** to reflect what
   actually got scaffolded.

4. **Don't implement the safety guard's real logic yet** — that starts
   next session per the build order. It's fine for the stub class to
   exist and raise `NotImplementedError`.

If anything in the reference docs seems ambiguous or you'd design it
differently, tell me before scaffolding around your own assumption — I'd
rather adjust the docs than have code and docs drift apart from turn one.

# Loadwright

> **Status: pre-release scaffold. Not usable yet.**
>
> The gem structure, configuration surface, and core value objects exist.
> The subsystems behind them are stubs that raise `NotImplementedError`.
> Nothing here runs a load test today.

A local developer diagnostic for Rails APIs. It discovers your endpoints from
an OpenAPI document and/or your own integration specs, seeds realistic data
through your FactoryBot factories at increasing scale, exercises every endpoint
under a scale x concurrency matrix, and reports where it falls over and why.

## Safety, before anything else

Loadwright generates real load against a real database. Its default posture:

- **Refuses to run outside `development` and `test`.** Running anywhere else
  requires four independent, explicit steps — see
  [`production-safety.md`](.claude/skills/loadwright-development/references/production-safety.md).
- **Never truncates tables.** Cleanup deletes only the rows Loadwright created,
  tracked by ID.
- **Never terminates database sessions.** Under contention it backs off,
  quarantines the endpoint, and moves on. It never tries to resolve contention.
- **Never sends real email, jobs, or outbound HTTP by default.** Side-effect
  containment is on unless you turn it off.
- **Only issues `GET`/`HEAD`/`OPTIONS` by default.** Mutating traffic is a
  separate opt-in.

## Documentation

The full design lives in this repository and is the source of truth until the
real README lands:

- [`CLAUDE.md`](CLAUDE.md) — what this project is, the safety rule that
  overrides everything else, architecture, and build order.
- [`AGENTS.md`](AGENTS.md) — operational reference for AI agents helping
  someone configure, run, or interpret Loadwright.
- [`.claude/skills/loadwright-development/references/`](.claude/skills/loadwright-development/references/)
  — per-subsystem design references.

## For AI Agents

If you are an AI agent helping someone configure, run, or interpret Loadwright,
start at [`AGENTS.md`](AGENTS.md) in the repository root.

It is a dense, machine-oriented operational reference covering setup procedure,
a configuration cookbook keyed by task, a symptom-to-fix diagnostic table,
report interpretation rules, safety invariants you must not violate, and known
agent antipatterns. It is written for machine consumption and is not intended
to be pleasant human reading.

Humans should keep reading this README instead.

## Requirements

- Ruby >= 3.1
- Rails >= 7.0 — `ActiveSupport::IsolatedExecutionState` is what makes
  per-request metric correlation correct under concurrency.

## License

MIT. See [`LICENSE.txt`](LICENSE.txt).

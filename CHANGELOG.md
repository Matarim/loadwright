# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Nothing yet.

## [0.0.1] — 2026-08-24

First public release. Pre-1.0: the CLI surface and config keys are stable enough
to document but not yet frozen.

### Added

**The tool itself**

- `loadwright run` — discovers a Rails API's endpoints, seeds data through the
  app's own FactoryBot factories at increasing scale, exercises every endpoint
  under a scale × concurrency matrix, and writes a report. `--dry-run` is the
  default and sends zero requests.
- `loadwright record --specs <path>` — runs the app's own request specs and
  records the requests they make, so discovery can resolve real path parameters
  instead of sending example IDs that 404.
- `loadwright runs list`, `baseline set`, `compare` — persisted run history and
  regression comparison against a designated baseline.
- `rails generate loadwright:install` — writes a fully documented initializer,
  adds `tmp/loadwright/` to `.gitignore`, and pre-fills discovery settings from
  what it finds on disk.

**Discovery** — OpenAPI/Swagger documents, recorded integration specs, and Rails
route introspection, merged on `(path template, verb)`. A named OpenAPI document
that is missing or only partly parseable fails loudly rather than silently
producing a partial endpoint list.

**Analysis** — N+1 detection by both repeated-query pattern and by slope against
*returned* record count (which is what catches the N+1 a paginated endpoint hides
from a seeded-scale measurement); missing pagination; over-fetch hints;
`EXPLAIN`-based index analysis on PostgreSQL, MySQL and SQLite; latency
percentiles; db/view/GC time breakdown; cold-vs-warm cache; a static
pool-vs-server-threads check.

**Reporting** — self-contained HTML (no external assets), Markdown and JSON,
all rendered from one structure. Every run states what it could and could not
measure, and why.

### Safety

- Refuses to run outside `development` and `test`. Running anywhere else requires
  four separate things: `allow_production`, an app-specific
  `confirmation_phrase`, `--i-understand-the-risk`, and that phrase typed
  interactively. A dry run is the default, and `--execute` is what overrides it.
- Remote HTTP targets bypass local environment detection entirely, so they are
  treated as production-adjacent regardless and asked to identify themselves.
  The target's answer is authoritative for *refusal* and never for *approval*.
- Cleanup deletes only the rows Loadwright created, tracked by primary key. It
  never truncates a table.
- Mail delivery, background jobs and outbound HTTP are suppressed by default. If
  containment cannot be enforced the run aborts rather than proceeding
  unprotected.
- Mutating verbs are skipped unless `allow_mutating_requests` is set.
- Database contention triggers a five-rung retreat — backoff, step down,
  quarantine, cool down, abort. Loadwright never terminates a database session.
- `SIGINT`/`SIGTERM` stop the run, tear down any booted server, delete seeded
  rows, and write a partial report marked as partial.
- Every run records the safety decision that permitted it, so a run's provenance
  is auditable after the fact.

### Requires

`webmock` in your `:development, :test` group. `block_outbound_http` is on by
default and webmock is what enforces it; without it `--execute` refuses rather
than proceeding unprotected. It is not a hard dependency, because it is a
testing library with opinions of its own and forcing a version on a host app
would be worse than asking. `--dry-run` works without it, and warns.

### Known limitations

Stated here rather than left to be discovered:

- **Memory and connection-pool pressure are not measured.** The trackers exist
  but nothing in a run collects from them, so no allocation figure or pool sample
  reaches a report. Every run says so explicitly instead of reporting a number.
  The static pool-vs-threads check *does* work and is a real finding, but it is a
  configuration comparison, not an observation of pressure.
- **Concurrency findings need `execution_mode = :http`.** In-process execution
  has no server thread pool; those signals are reported unavailable, never as
  zero.
- **An `:http` run against a server Loadwright did not boot** cannot be
  instrumented, so it reports honestly reduced capability rather than confident
  numbers it never measured.
- **GraphQL is not supported.** Path-based discovery does not fit one endpoint
  with N resolvers.
- **Multiple databases and read replicas** are not modelled; pool tracking
  assumes a single pool.
- **Tested on Ruby 4.0 and Rails 8.1.** The gemspec floor of Ruby 3.1 / Rails 7.0
  reflects the APIs used, not a tested matrix.

[Unreleased]: https://github.com/Matarim/loadwright/compare/v0.0.1...HEAD
[0.0.1]: https://github.com/Matarim/loadwright/releases/tag/v0.0.1

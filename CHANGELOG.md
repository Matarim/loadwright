# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Cleanup now covers rows your app created.** Previously it tracked only what the
  factories wrote, so a run against a `POST` endpoint left one record per request
  behind — and so did a `GET` that writes an audit row or touches a `last_seen_at`.
  The table is learned from the INSERT fingerprints already being collected, so it
  works in both execution modes with no extra instrumentation, and it reuses the
  same pre-seed watermark: still strictly id-bounded, still never a `TRUNCATE`,
  still incapable of reaching a row that existed before the run.
  Governed by `cleanup_request_created_rows` (default `true`).
- **`auth_login`** — name the login request your own clients make, and where the
  token is in the answer, instead of writing the code that mints one inside your
  initializer. Issued once per credential before the run, through the same
  transport; those requests are setup and are never measured or reported as
  endpoints. Supports a JSON path or a response header (for session auth), and a
  list of credentials, which is how you get multi-identity traffic. A failed login
  stops the run with the status, and never echoes the credential back.
- **Fix suggestions on N+1 findings.** The report already named the repeated query
  and the file and line; it now also names the shape of the likely fix. Notably it
  does *not* say "add `includes`" for a repeated `COUNT`, where that advice is
  wrong — a preloaded association is still counted with a query unless the code
  stops counting, so the fix is a counter cache or `.size` on a loaded collection.
  Suggestions are advisory: they never change an outcome state or the exit code,
  and a query shape that is not recognised gets no suggestion rather than a
  guessed one.
- **GraphQL operations are discovered and measured.** Every GraphQL operation is a
  `POST` to one path, so path-based discovery reported an entire API as one row.
  Operations are now the unit of work, sourced from `.graphql` documents or an
  inline list — never generated from the schema, because a generated query measures
  traffic the app never receives. Two consequences worth naming: a `query` counts as
  a **read** despite travelling by `POST`, so measuring one does not require
  `allow_mutating_requests`; and a failed GraphQL query answers **HTTP 200**, so the
  validity gate now recognises the `errors` envelope and reports those endpoints
  `inconclusive` instead of fast and healthy.
- **GraphQL pagination is swept.** A paginated operation's query count is flat
  against seeded scale, so only varying the page size reveals an N+1 behind it —
  and in GraphQL the page size is a variable inside the document rather than a
  query parameter. Loadwright varies a variable named in
  `graphql_page_size_variables` across `page_size_sweep`, and counts returned
  records from a plain list field or from `edges`/`nodes` on a Relay connection.
  An operation that hardcodes `first: 10` is reported as unsweepable, with the
  parameterisation to make it sweepable, rather than measured three times at the
  same size and reported flat.
- **Per-resolver attribution for GraphQL.** `trace_with
  Loadwright::Instrumentation::GraphqlTracer` on your schema makes findings name
  the resolver — "resolved by `Author.postCount`" — rather than only the operation.
  The tracer no-ops outside a run, so it is safe to leave installed, and `graphql`
  remains a non-dependency: it is a plain module your schema opts into.

### Fixed

- **`loadwright record` broke any rswag-based suite.** It called `RSpec.reset`,
  which replaces the `Configuration` singleton and discards every setting a gem
  registered at *require* time. Those gems are already loaded by then — Loadwright
  boots the app first — so their `require` in `spec_helper` is a no-op and they
  never re-register. rswag's `openapi_root` vanished and the host's own
  `spec_helper` died with `NoMethodError` before a single example ran. It now calls
  `RSpec.world.reset`, which clears example groups without touching configuration.
  A suite that errors before recording also now says so, instead of reporting "the
  specs ran but made no recordable requests" — which sent people to rewrite tests
  that were fine.
- **Rack-mounted APIs collapsed to their mount point.** Rails reports
  `mount MyApi => "/internal/api"` as one route, so every endpoint behind it recorded
  the same template, merged into a single endpoint, and got requested at the bare
  mount point — a 404. Templates are now recovered from the recorded paths by
  promoting id-shaped segments, so `/internal/api/widgets/{widget_id}/customer` comes
  back with its id intact. Affects Grape, Sinatra, Roda and any mounted Rack app.
- **A custom auth header was written to the recording in plaintext.**
  `redact_header_patterns` matched `Authorization` but not `X-Account-Key`, so an app
  using a custom auth header had its live credential written to disk while `Cookie`
  beside it was redacted. The defaults are now broad — `auth`, `token`, `secret`,
  `credential`, `session`, `signature` — because a custom auth header is the norm
  and the cost of redacting a harmless one is nothing.
- **One broken endpoint aborted the whole run.** The circuit breaker is global, so
  a single endpoint returning 500 on every request tripped it and abandoned every
  endpoint the sweep had not yet reached. When errors are concentrated in one
  endpoint (≥80%), that endpoint is now quarantined as `inconclusive` and the run
  continues. Errors spread *across* endpoints still abort — that is the case the
  breaker exists for.
- **An unparseable OpenAPI document had no triage path.** The refusal is correct and
  unchanged, but 20 truncated errors on a terminal is not something a team can act
  on. The full list is now written to `openapi-errors.json`, the message says how
  many paths are affected out of how many ("52 errors across 31 of 44 paths"), and
  it names the two discovery sources that need no document at all.
- **`record` now warns about pending migrations** before running your specs, instead
  of letting every spec file fail with the same stack trace.
- **A foreign exception's message is bounded** where it crosses into our output.
  Ruby builds a `NoMethodError`'s message from the receiver's inspect, so one raised
  against a large object can bury the four words that matter.
- **The two execution modes sent different content types for the same request.**
  `:http` JSON-encoded a structured body; `:in_process` form-encoded it, turning
  every value into a string. Invisible for most REST params, which Rails coerces
  anyway — and fatal for GraphQL, where `Int!` rejects `"3"`.
- **Authentication was never sent.** `IdentityPool#resolve!` was called from nowhere
  in `lib/`, so a configured `auth_token_provider` produced a pool whose tokens were
  never resolved: every request went out unauthenticated, every endpoint returned
  401/403, and the report told the user their token was probably misconfigured. It
  was not — the tool never sent it. This is the failure `AGENTS.md` documents as the
  most common on a first run, and it was self-inflicted. The pool is now resolved
  once, before any request is issued, and `examples/sample_app` has an endpoint that
  actually checks a token so no fixture can hide it again.
- `auth_strategy` documented `:none` and `:custom`, neither of which exists, and
  omitted `:header` (`X-Api-Key`), which does. All three real strategies are now
  documented with the header each sends, and an invalid value is rejected at
  startup rather than mid-run.

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
- **GraphQL subscriptions are skipped.** They are not answered over a plain HTTP
  POST, so there is nothing to measure. Queries and mutations are fully supported.
- **Multiple databases and read replicas** are not modelled; pool tracking
  assumes a single pool.
- **Tested on Ruby 4.0 and Rails 8.1.** The gemspec floor of Ruby 3.1 / Rails 7.0
  reflects the APIs used, not a tested matrix.

[Unreleased]: https://github.com/Matarim/loadwright/compare/v0.0.1...HEAD
[0.0.1]: https://github.com/Matarim/loadwright/releases/tag/v0.0.1

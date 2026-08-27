# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.0.3] — 2026-08-27

Seven fixes from a second round of outside integration. Two of them are the same
species as the round-2 batch and worth naming as such: **the fix landed but the
last mile did not.** Environment tagging was added and tagged the wrong value;
orphan adoption existed and ran on one code path only. Neither was a design
problem — both were a step short of complete, and both reported all clear while
incomplete, which is the failure mode this tool exists to argue against.

### Fixed

- **A recording now records which DATABASE it was made against**, sampled inside
  the spec that issued the request. 0.0.2 added the environment tag and then
  sampled it in the CLI process — which boots before the specs run and does not
  follow them to the test database. A recording made entirely of test ids was
  tagged `development`, the guard compared `development` to `development`,
  passed, and dropped nothing. The environment name was only ever a proxy for
  "did these ids come from the database this run measures"; the database name
  answers it directly, and the environment comparison remains the fallback for a
  recording that carries no database. A guard that reports all clear without
  working is worse than no guard.
- **Cleanup no longer spares a row because another table has one with that
  number.** The associated-row sweep skipped an exclusion list built by
  flattening every resource's tracked ids into one array and applying it to a
  single table. Ids are per-table sequences, so the collisions were spared: rows
  created by the run, above that table's own watermark, left behind because some
  other table had a row with that number — while the log reported the count of
  what cleanup had decided to delete. Cleanup now also asks the database
  afterwards, and says so if anything created during the run is still there.
  Silent litter accumulates run over run and is invisible until somebody counts.
- **Fix suggestions name an association you can actually type.** The name came
  from hand-rolled suffix stripping, which turned a table ending in `ses` into a
  non-word — `includes(:<nonword>)` raises `AssociationNotFoundError` if you
  follow it. It now goes through ActiveSupport's inflector, which also means a
  host that registered an irregular inflection gets its own answer.
- **`includes` is no longer suggested for a repeat that does not scale.** A
  request that finds the same already-loaded row four times wears the same
  signature as a per-record N+1 inside one request — but not across cells: a
  per-record N+1 issues more queries as more records come back, and a fixed
  multiplier does not. Where that flatness is measured, the finding says so
  (`evidence.scaling: fixed`) and the advice becomes "pass the loaded object
  down, or memoize" instead of "preload". Where it was not measured, the advice
  is unchanged — flatness that was never measured is not flatness.
- **The request is rebuilt from what the recording actually held.** Discovery
  captured the query parameters and headers of a passing spec's request and the
  run sent neither, so an endpoint needing an `Accept` header answered 406 and
  one with a required query parameter answered 400 — coverage lost to the
  reconstruction rather than to anything about the app. Governed by
  `replay_recorded_headers` (default `Accept`, `Content-Type`) and
  `replay_recorded_query_params` (default `true`). Headers are replayed by name,
  never wholesale; the identity's auth header wins over a recorded one, and the
  page-size sweep's parameter wins over a recorded page size.
- **Unmapped recordings are named, not just counted.** A recorded request the
  router does not recognise is dropped and counted honestly — but those endpoints
  then appeared nowhere else, making them the one "could not measure" case with
  no row of its own. The samples were already collected at record time and thrown
  away at write time; they now travel with the recording.
- **One situation, one sentence.** Two endpoints returning 500 on every request
  were described two different ways depending on which mechanism noticed first —
  the validity gate, or error-concentration quarantine. Both now lead with the
  same sentence and the quarantine detail names the status it saw. The reason
  symbols stay distinct in the machine-readable output.

### Changed

- **The dry run says when the page-size sweep will not be able to run.** The
  sweep correctly refuses when the largest scale factor cannot fill the largest
  page. What was easy to underweight is the consequence: that sweep is one of two
  N+1 detectors and is specifically the one that catches an N+1 hiding behind
  pagination, so a paginated endpoint in the healthy list has had half the check
  applied. It is reachable from the shipped defaults, and it belongs in the dry
  run rather than in a report you read afterwards.
- **The generated initializer stops assigning two lists it is only documenting.**
  `production_hostname_patterns` and `page_size_parameters` now ship commented
  out with their current defaults named, the way `redact_header_patterns`
  already does. Assigning a copy of today's list freezes it: a release that
  learns to recognise a production host yours matches would never reach an app
  generated before it, and the safety list is the worst one in the file to
  freeze. Existing initializers are worth auditing for the same pattern.

### Note on `v0.0.2`

Bundler resolves the annotated tag `v0.0.2` to `d4f81e4`, the tag OBJECT. The
commit it points at is `1ac8a89` (`git rev-parse v0.0.2^{}`). The tag has not
moved; the two SHAs are the two halves of one annotated tag.

## [0.0.2] — 2026-08-27

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

- **`loadwright init`** — writes `config/initializers/loadwright.rb` with the settings
  most apps actually need, 77 lines instead of 497. `rails generate
  loadwright:install --minimal` does the same. Everything it omits keeps its default,
  which is the point: assigning a key freezes it at today's value.

### Fixed

- **Path parameters resolved to the primary key, and an explicit override could not
  override it.** An API routing on a public identifier — guid, slug, uuid, which is
  the norm for anything that declines to leak sequential ids — got its primary key
  substituted and 404'd every request. `path_param_overrides` sat *third* in the
  resolution order, behind two inferences, so the documented fix could not take
  effect. An override is now **first**; `factory_map` accepts `param:` to name the
  column the API routes on; and parameter names ending `_guid`, `_uuid`, `_slug`,
  `_code`, `_key`, `_token`, `_number` and `_ref` now map back to their resource
  rather than only `_id`.
- **An endpoint could request its own raw template.** A declared-but-empty parameter
  list won over the template, so a path visibly containing `{id}` claimed to have no
  parameters and went out as a URL — `URI::InvalidURIError`, once per request. The
  template is now authoritative, and a resolved path still containing `{` is reported
  unresolved rather than requested.
- **Recorded ids came from the wrong database.** `record` runs specs against `test`;
  `run` measures `development`. Recordings now carry the environment they were made
  in, and values from a different one are dropped with a warning while the parameter
  stays declared.
- **The generated initializer replaced the redaction defaults.** Assigning
  `redact_header_patterns` froze it, so the broadened credential list did not reach
  anyone who had generated a file before it shipped. That key is now commented out,
  with `redact_additional_patterns` shown as the way to add.
- **`--specs` kept only the last value.** It now accumulates.
- **Reconstructed mounted paths carried a doubled slash**, and a query string could
  stop an id-shaped segment being recognised — leaving one endpoint per record.
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

[Unreleased]: https://github.com/Matarim/loadwright/compare/v0.0.3...HEAD
[0.0.3]: https://github.com/Matarim/loadwright/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/Matarim/loadwright/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/Matarim/loadwright/releases/tag/v0.0.1

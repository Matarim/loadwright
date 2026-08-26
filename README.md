# Loadwright

**Find out where your Rails API falls over — on your laptop, before anyone else sees it.**

Loadwright discovers every endpoint in your API, seeds your database at increasing
scale using your own FactoryBot factories, hits each endpoint with realistic
traffic, and tells you which ones degrade and why.

It sits in a gap between tools you probably already use. [Bullet][bullet] and
[Prosopite][prosopite] tell you an N+1 happened while you were clicking around —
they need you to exercise the code first. [n_plus_one_control][npoc] locks in a
query count you already know about, which means you have to find it before you can
guard it. An APM tells you the truth about production, once production is already
suffering. Loadwright is the exploratory step before all of those: it goes looking,
at scale, on demand, and hands you a ranked list of what to fix. What it finds is a
good candidate for an `n_plus_one_control` assertion afterwards.

It is a **local developer diagnostic tool**. It is not a CI gate, not an APM, and
not a capacity planner — see [When not to use this](#when-not-to-use-this).

[bullet]: https://github.com/flyerhzm/bullet
[prosopite]: https://github.com/charkost/prosopite
[npoc]: https://github.com/palkan/n_plus_one_control

---

## Safety first — read this before installing

You are considering pointing a load generator at a database. That deserves a
straight answer about what this thing will and will not do, *before* you install it.

### It refuses to run outside development and test

With zero configuration, Loadwright runs in `development` and `test` and nowhere
else. Anywhere else it aborts before issuing a single request.

Getting it to run against a production-shaped environment requires **four separate
things at once**, and no single one of them is enough:

1. `config.allow_production = true` in the initializer — deliberately not a CLI
   flag, so it cannot be done by editing a shell command;
2. `config.confirmation_phrase` set to a phrase specific to your app;
3. the `--i-understand-the-risk` flag;
4. that phrase typed, interactively, at the prompt.

If any layer cannot be evaluated, the run is refused rather than allowed. There is
no generic fallback phrase — an unresolvable one refuses instead of substituting
something guessable. The environment gate also applies to `http_target_url`: a
non-loopback target means your local `Rails.env` is describing the wrong process
entirely, so the target is treated as production-adjacent and asked to identify
itself. Its answer can **refuse** a run but never **approve** one.

Every safety decision made during a run is recorded in the report, so a run's
provenance is auditable after the terminal is gone.

### What this tool will never do

- **Never kills, cancels, or terminates a database session.** When it detects lock
  or pool contention it backs off, quarantines the endpoint, and moves on. It never
  tries to resolve contention — only to retreat from it.
- **Never truncates a table.** Cleanup deletes only the rows Loadwright itself
  created, tracked by primary key. Your local seed data and hand-crafted fixtures
  survive.
- **Never sends real email, performs real jobs, or calls real third-party APIs.**
  Containment is on by default, and if it *cannot* be enforced the run aborts rather
  than proceeding unprotected — because believing a run was contained when it was
  not is worse than not running it.
- **Never issues a mutating request** unless you set
  `config.allow_mutating_requests = true`. `POST`, `PUT`, `PATCH` and `DELETE`
  endpoints are discovered, reported as skipped, and not called. If you do turn
  them on, note the limit of the cleanup guarantee above: Loadwright deletes the
  rows *it* seeded, and it does not track rows your app created in response to a
  request. A few hundred `POST`s leave a few hundred records behind, and clearing
  those is yours. See [`examples/mutating_endpoints`](examples/mutating_endpoints).
- **Never phones home.** No telemetry, no version checks, no network traffic except
  to the app under test.

### Two more things worth knowing

**The default is a dry run.** `loadwright run` with no flags resolves everything,
prints the plan, and sends zero requests. You have to type `--execute` to generate
traffic.

**Ctrl-C is safe.** SIGINT and SIGTERM are trapped: the run stops issuing requests,
tears down any server it booted, deletes the rows it seeded, and writes a partial
report marked as partial. Interrupting is a supported way to end a run, not a way
to leave a mess behind.

---

## 60-second quickstart

```ruby
# Gemfile
group :development, :test do
  gem "loadwright"
end
```

```console
$ bundle install
$ bundle exec rails generate loadwright:install
      create  config/initializers/loadwright.rb
      append  .gitignore
        none  no OpenAPI document found; set openapi_spec_paths if you have one
       found  request specs: spec/requests
        next  review config/initializers/loadwright.rb before running anything
        next  set auth_token_provider unless the API is fully public
        next  `bundle exec loadwright run --dry-run` sends zero requests
```

Then look before you leap. This is real output, from the fixture app in
[`examples/sample_app`](examples/sample_app):

```console
$ bundle exec loadwright run --dry-run
loadwright: booting the application (config/environment.rb)
loadwright: 8 endpoint(s) to exercise — 1 discovered but not exercisable — sources: route 9
loadwright: DRY RUN — resolving the matrix, sending zero requests
  8 endpoint(s), 40 cell(s), 840 request(s)
  estimated 0.4 minute(s) at an assumed 25ms per request
  loadwright: contention backoff budget — 3.75s per event (250ms + 500ms + 1000ms + 2000ms), 5.00s cooldown per quarantine, worst case 34.1s before a global abort (+ up to 30% jitter)
  GET /api/v1/admin/stats
    seed_scale: 2 cell(s)
    page_size: 3 cell(s)
  GET /api/v1/authors
    seed_scale: 2 cell(s)
    page_size: 3 cell(s)
  GET /api/v1/posts
    seed_scale: 2 cell(s)
    page_size: 3 cell(s)

loadwright: dry run only — nothing was requested and no report was written.
  re-run with --execute to measure 8 endpoint(s).
```

Read that endpoint list. If it contains something you did not expect — an admin
route, a destructive path — fix `excluded_paths` before going further. Then:

```console
$ bundle exec loadwright run --execute
loadwright: booting the application (config/environment.rb)
loadwright: 8 endpoint(s) to exercise — 1 discovered but not exercisable — sources: route 9
loadwright: 40 cell(s), 840 request(s), estimated 0.4 minute(s)

loadwright: 9 endpoint(s) — 3 healthy, 2 with findings, 4 inconclusive
  GET /api/v1/authors: n_plus_one_pattern_match
  GET /api/v1/authors: n_plus_one_slope
  GET /api/v1/posts: n_plus_one_pattern_match
  report: tmp/loadwright/20260824-143511-report.html
  report: tmp/loadwright/20260824-143511-report.md
loadwright: deleted 90 seeded post row(s)
loadwright: deleted 270 associated comments row(s)
loadwright: deleted 90 associated authors row(s)
```

And the report says, in part:

| Endpoint | Finding | Confidence | Detail |
|---|---|---|---|
| GET /api/v1/authors | `n_plus_one_pattern_match` | high | the same query ran 130 times in a single request: `SELECT COUNT(*) FROM "posts" WHERE "posts"."author_id" = ?` — originates in controller `app/controllers/api/v1/authors_controller.rb#index:30` |
| GET /api/v1/authors | `n_plus_one_slope` | high | query count grows with the number of records returned (1.0 extra queries per additional record). This is the signature pagination hides from a seeded-scale measurement. |
| GET /api/v1/posts | `missing_pagination` | high | response size grows with the number of rows in the table (correlation 1.0 against seeded scale). The endpoint returns an unbounded collection. Note the query count may be perfectly flat — one query can load ten thousand rows. |

Note the second row. `/api/v1/authors` **paginates**, so its query count stays
completely flat as the table grows — a seeded-scale measurement calls it healthy.
Only sweeping the page size reveals it. That blind spot is the reason Loadwright
runs [two sweeps](#reading-the-report).

Note also **4 inconclusive**. Those are endpoints Loadwright could not validly
measure, and they are reported separately rather than counted as passing. That
distinction is the most important thing in the output — see
[Reading the report](#reading-the-report).

---

## For AI Agents

If you are an AI agent helping someone configure, run, or interpret Loadwright,
start at [`AGENTS.md`](AGENTS.md) in the repository root.

It is a dense, machine-oriented operational reference covering setup procedure, a
configuration cookbook keyed by task, a symptom-to-fix diagnostic table, report
interpretation rules, safety invariants you must not violate, and known agent
antipatterns. It is written for machine consumption and is not intended to be
pleasant human reading.

Humans should keep reading this README instead.

---

## Installation

```ruby
# Gemfile
group :development, :test do
  gem "loadwright"
end
```

**The `:development, :test` group is not optional.** Loadwright seeds data and
generates load; it has no business being loadable in production. But Rails
evaluates `config/initializers/*.rb` in *every* environment, including the one where
the gem is absent — so the generated initializer wraps everything in:

```ruby
if defined?(Loadwright)
  # ...
end
```

Without that guard, booting production raises `NameError` and your app does not
start. The generator writes it for you; do not remove it. (Bullet's initializer
does the same thing for the same reason.)

**Add `webmock` to the same group** if it isn't there already:

```ruby
group :development, :test do
  gem "loadwright"
  gem "webmock"    # required for config.block_outbound_http, which is on by default
end
```

Blocking outbound HTTP is how Loadwright keeps a load test from calling real
third-party APIs a few hundred times from your laptop, and `webmock` is what
enforces it. Without it, `--execute` refuses to run rather than proceeding
unprotected. It is not a hard dependency of the gem because it is a testing
library with opinions of its own, and forcing a version on your app would be
worse than asking. (`--dry-run` still works without it — it issues no requests —
and will warn you.)

If you'd rather not add it, set `config.block_outbound_http = false` and accept
that a run may call third-party APIs for real.

Then:

```console
$ bundle exec rails generate loadwright:install
```

This writes `config/initializers/loadwright.rb` with the full key surface
commented and documented, adds `tmp/loadwright/` to `.gitignore`, and pre-fills the
discovery section based on what it finds on disk.

**Requirements:** Ruby >= 3.1, Rails >= 7.0. The Rails floor is
`ActiveSupport::IsolatedExecutionState`, which is how per-request instrumentation
stays correctly attributed under concurrency; there is no 6.1 fallback.

---

## Configuration walkthrough

Everything below is set inside the generated initializer:

```ruby
if defined?(Loadwright)
  Loadwright.configure do |config|
    # ...
  end
end
```

Every key is shown with its default. You do not need to set any of them to get a
useful first run — the two worth setting early are `auth_token_provider` and
`factory_map`.

### Execution

How requests are issued. See [Choosing an execution mode](#choosing-an-execution-mode).

```ruby
config.execution_mode = :in_process          # :in_process | :http
config.allow_in_process_threading = false    # in-process concurrency is a lie; keep this off
config.http_server_command = nil             # nil = auto-detect Puma. $PORT is expanded.
config.http_boot_timeout = 30                # seconds to wait for the app to answer
config.http_target_url = nil                 # target a server Loadwright did not boot
config.allow_remote_http_target = false      # required for any non-loopback target
```

`allow_in_process_threading` exists because `:in_process` has no real server thread
pool — concurrency findings there would be fabricated. Leave it off unless you know
exactly why you want it.

### Safety

```ruby
config.enabled_environments = [:development, :test]
config.production_hostname_patterns = [/\.rds\.amazonaws\.com\z/, /^prod-/, /\.internal\z/]
config.allow_production = false              # layer 3 of 4; see Safety, above
# config.confirmation_phrase = nil           # no generic fallback: unresolvable refuses
config.allow_mutating_requests = false       # POST/PUT/PATCH/DELETE are skipped by default
config.max_error_rate_before_abort = 0.2     # circuit breaker; contention is excluded from this
config.long_run_confirmation_threshold_minutes = 10
```

`max_error_rate_before_abort` counts *application* errors. Contention errors are
structurally excluded from the numerator — otherwise a busy database would trip the
breaker and the run would blame your app for someone else's lock.

### Side-effect containment

```ruby
config.suppress_mail_delivery = true
config.suppress_background_jobs = true
config.block_outbound_http = true
config.outbound_http_allowlist = ["localhost", "127.0.0.1"]
config.abort_if_containment_unavailable = true
```

Turning `abort_if_containment_unavailable` off means a run may proceed while sending
real mail and performing real jobs, once per request. It is a deliberate, explicit
choice; the report records that you made it.

### Response analysis

A performance verdict is only attached to a response that proved it did the work.

```ruby
config.require_successful_response = true
config.require_schema_valid_response = true
config.warn_on_empty_response_with_seeded_data = true
config.page_size_parameters = ["per_page", "limit", "page[size]", "pageSize"]
config.page_size_sweep = [5, 25, 100]
config.detect_overfetching = true
config.max_response_bytes_warning = 1_048_576
config.payload_growth_correlation_threshold = 0.8
config.serializer_attribution = true
```

### Contention handling

Start with a profile; override individual keys only if you need to. See
[Tuning contention handling](#tuning-contention-handling).

```ruby
config.contention_profile = :balanced        # :conservative | :balanced | :aggressive
config.lock_timeout_ms = 3_000
config.statement_timeout_ms = 10_000
config.abort_on_unhealthy_baseline = true
config.health_poll_interval_ms = 500
config.latency_degradation_multiplier = 4.0
config.degradation_windows_before_backoff = 3
config.backoff_initial_delay_ms = 250
config.backoff_multiplier = 2.0
config.backoff_max_delay_ms = 15_000
config.backoff_jitter = 0.3
config.max_backoff_attempts = 4
config.post_quarantine_cooldown_ms = 5_000
config.max_consecutive_quarantines = 3
config.max_health_check_retries = 3
```

### Discovery

See [Discovery modes](#discovery-modes).

```ruby
config.openapi_spec_paths = []               # defaults to swagger/v1/swagger.yaml if present
config.integration_spec_paths = []           # defaults to spec/requests if present
config.route_discovery = true                # gap-filling only
config.excluded_paths = [%r{^/rails/}, %r{^/admin/}, %r{^/health}]
config.included_paths = nil                  # nil = everything not excluded
config.path_param_overrides = {}             # e.g. { "/api/v1/orders/{id}" => { "id" => 42 } }
config.graphql_path = nil                    # e.g. "/graphql"; see GraphQL below
config.graphql_operations = []               # inline operations
config.graphql_document_paths = []           # globs of .graphql files
config.graphql_page_size_variables = %w[first last pageSize limit]
```

### Authentication

Leaving `auth_token_provider` unset is the single most common cause of a first run
coming back all-inconclusive.

```ruby
config.auth_strategy = :bearer_token
config.auth_token_provider = nil             # a callable returning a token
config.auth_login = nil                      # or log in for one; see below
config.test_identity_pool_size = 5           # single-identity traffic lies about caching
config.default_headers = { "Accept" => "application/json" }
```

The provider is called with **no arguments**. It may return a single token, or a
collection — and a collection is much better, because traffic from a single identity
can make a badly-scoped query look fine on a multi-tenant app:

```ruby
# One identity. Works, and Loadwright warns that all traffic is one identity.
config.auth_token_provider = -> { ENV.fetch("LOADWRIGHT_TOKEN") }

# Better: a collection, rotated across requests.
config.auth_token_provider = -> { User.limit(5).map { |user| JwtIssuer.for(user) } }
```

If the provider raises, or returns nothing usable, the run aborts rather than
producing a report full of 401s that all read as `inconclusive`.

### Seeding

```ruby
config.factory_bot_enabled = true
config.factory_map = {}                      # see FactoryBot setup, below
config.scale_factors = [1, 10, 50, 200]
config.seed_batch_size = 50
config.seed_cleanup_strategy = :delete_created_rows   # never a TRUNCATE
config.cleanup_request_created_rows = true   # also clean up rows your app created
config.unique_field_generator = nil          # nil = report the collision, do not paper over it
```

### Load shape

```ruby
config.concurrency_levels = [1, 5, 20]
config.requests_per_endpoint_per_level = 25
config.request_timeout = 5
config.warmup_requests = 3
```

### Instrumentation

```ruby
config.detect_n_plus_one = true
config.track_memory_allocations = true
config.track_connection_pool = true
config.disable_query_cache_during_run = true # the query cache hides textbook N+1s
config.track_time_breakdown = true
config.track_gc_stats = true
config.run_explain_on_slow_queries = true    # ANALYZE is SELECT-only, behind a whitelist
config.explain_top_n_queries = 5
config.seq_scan_row_threshold = 10_000
config.measure_cold_cache = true
config.track_pg_stat_statements = true
config.slow_query_threshold_ms = 100
config.min_samples_for_percentiles = { p50: 20, p95: 100, p99: 500 }
config.check_pool_vs_server_threads = true
config.jobs_enqueued_warning_threshold = 10
```

`min_samples_for_percentiles` is why a default run reports p50 and not p99: 25
samples cannot support a 99th percentile, and printing one anyway is noise with a
decimal point. Percentiles the sample cannot support are omitted, not caveated.

### Run history and comparison

```ruby
config.run_history_dir = "tmp/loadwright/runs"
config.run_history_limit = 50
config.regression_threshold_pct = 20
config.fail_on_regression = false
```

### Redaction

Applied at *collection* time, so secrets never reach the persisted run record
either — not just the rendered report.

```ruby
config.honor_rails_filter_parameters = true
config.redact_header_patterns = [/authorization/i, /cookie/i, /api[-_]?key/i]
config.redact_sql_bind_values = true
config.include_response_bodies = false
config.redact_additional_patterns = []
```

### Thresholds

```ruby
config.fail_on_n_plus_one = false
config.p95_latency_budget_ms = { default: 500 }   # or per-endpoint keys
```

The budget is checked at the highest percentile the sample can actually support,
and the substitution is stated in the report. A median above your p95 budget is a
*stronger* result than the one you asked for, so it is reported rather than
withheld.

### Reporting

```ruby
config.report_formats = [:html, :markdown]   # :html | :markdown | :json
config.report_output_dir = "tmp/loadwright"
config.report_filename_pattern = "%Y%m%d-%H%M%S-report"
config.write_partial_report_on_abort = true
```

### Notifications

```ruby
config.slack_webhook_url = nil
```

---

## Choosing an execution mode

This is the first real decision you make, and the default is not the lesser option
— it is the right one for most questions most of the time.

| Your question | Mode | Why |
|---|---|---|
| Does this endpoint have an N+1? | `:in_process` | A single-request property. Concurrency adds nothing. |
| Is my query structure right after this refactor? | `:in_process` | Same. |
| Does this endpoint over-fetch or forget to paginate? | `:in_process` | Same. |
| Is my connection pool big enough? | `:http` | Needs a real server thread pool. |
| What happens at 20 concurrent requests? | `:http` | Same. |
| What is real client-observed latency? | `:http` | In-process skips the whole HTTP stack. |

`:in_process` dispatches through `ActionDispatch::Integration` in your own process.
Zero setup, fast, and it sees everything about how a single request behaves.

`:http` boots a real Puma, issues real HTTP, and correlates instrumentation back
over a request-ID header. It costs a server boot and needs the app to be bootable
standalone.

**What is unavailable in `:in_process`** — and this matters, because an absent
finding must never read as a clean one:

- latency under concurrency
- connection pool exhaustion
- true client-observed latency
- clean memory attribution (the harness shares the app's process)

Loadwright does not silently omit these. Every report has a "What this run could
measure" section naming each unavailable signal *and the reason*:

| Signal | Status | Why not |
|---|---|---|
| latency under concurrency | unavailable | in-process execution has no server thread pool; use execution_mode = :http |
| clean memory attribution | unavailable | harness shares the app's process; use execution_mode = :http |

Capability is a property of how metrics are *collected*, not of the mode you asked
for. An `:http` run against a server Loadwright did not boot cannot be instrumented
— so it reports honestly reduced capability rather than confident numbers it never
measured. Capability can also degrade mid-run, and results stay attributed to the
capability actually in effect when they were collected.

---

## Discovery modes

Three sources, merged on `(path template, verb)`.

| Source | Gives you | Costs |
|---|---|---|
| **OpenAPI/Swagger** | Paths, verbs, parameter schemas, example values, response schemas for validation | You need a document, and it must be accurate |
| **Integration-spec recording** | Real requests your specs actually make, with real path params and real auth | One run of your specs |
| **Route introspection** | Every route Rails knows about | No example request, so many endpoints end up unexercisable |

**Precedence when they disagree:** OpenAPI supplies schemas; a recording supplies
real values; routes fill gaps. Route discovery is deliberately last — it knows a
path exists but nothing about what a valid request to it looks like.

If an OpenAPI document you *named explicitly* is missing or only partly parseable,
discovery fails loudly rather than continuing. A partial discovery reports endpoints
that were never tested as simply absent, and a report of four endpoints that reads
like it covers forty is worse than an error.

### GraphQL

GraphQL has no endpoints to discover: every query and mutation is a `POST` to the
same path, so path-based discovery finds exactly one endpoint and reports your
whole API as a single row. That matters more than it sounds — GraphQL N+1s are
per-resolver, and one row cannot tell you which resolver is the problem.

So the unit of work is the named **operation**:

```ruby
config.graphql_path = "/graphql"

# From the .graphql documents you already keep...
config.graphql_document_paths = ["app/graphql/queries/*.graphql"]

# ...or inline. Parameterise the page size as `$first` — see Pagination below.
config.graphql_operations = [
  { name: "PostsWithComments",
    query: "query PostsWithComments($first: Int!) { posts(first: $first) { id comments { id } } }",
    variables: { "first" => 25 } }
]
```

Each operation becomes its own row: `POST /graphql (PostsWithComments)`.

Three things worth knowing:

**A `query` is a read, even though it's a `POST`.** Classifying by HTTP verb would
mark your entire API as mutating and make `allow_mutating_requests` — a safety
opt-in for endpoints that *write* — a prerequisite for measuring reads. Operation
type decides instead: `query` runs freely, `mutation` is held behind that gate like
any other write.

**A failed GraphQL query answers `200`.** `{"errors": [...]}` with no data is a
total failure that looks, to anything checking the HTTP status, like a fast healthy
endpoint. Loadwright checks for the GraphQL error envelope and reports those
`inconclusive`, quoting the first error.

**Loadwright will not generate operations from your schema.** It could introspect
and assemble queries, but a generated query exercises field combinations nobody
asks for and measures traffic your app will never receive.

#### Pagination

A paginated operation returns the same page whatever your table holds, so its
query count is **flat against seeded scale** — and a seeded-scale measurement
calls it healthy. Only varying the page size moves it. In GraphQL that page size
lives in a variable inside the document, not in a query parameter, so it has to be
declared:

```ruby
config.graphql_operations = [
  { name: "PagedAuthors",
    query: "query PagedAuthors($first: Int!) { authors(first: $first) { nodes { id postCount } } }",
    variables: { "first" => 25 } }
]
```

Loadwright finds `$first` by name (see `graphql_page_size_variables`), varies it
across `page_size_sweep`, and measures queries against **returned records** —
which is what catches the N+1. Relay connections are counted by `edges` or
`nodes`, and plain list fields by length.

An operation that hardcodes `first: 10` cannot be varied. Rather than measure the
same page three times and report the flat line as healthy, Loadwright skips the
sweep for that operation and tells you to parameterise it:

```
loadwright: POST /graphql (PostsWithComments) — PostsWithComments declares no
page-size variable, so its result size cannot be varied. Parameterise the
connection argument ($first: Int!) to make the returned-record slope available
for this operation.
```

#### Per-resolver attribution

By default a GraphQL finding names the operation, which for a query of any size is
"somewhere in here". Add one line to your schema and it names the resolver:

```ruby
class MySchema < GraphQL::Schema
  trace_with Loadwright::Instrumentation::GraphqlTracer
end
```

Findings then read:

```
the same query ran 40 times in a single request:
SELECT COUNT(*) FROM "posts" WHERE "posts"."author_id" = ?
  — resolved by Author.postCount
```

The tracer is a no-op unless a Loadwright run is in progress, so it is safe to
leave in place — it costs your app nothing in normal operation. Lazy fields are
traced too, which is where batched loaders do their work.

`graphql` is **not** a dependency of this gem. The tracer is a plain module that
only does anything when your schema opts in.

### Recording your specs

```console
$ bundle exec loadwright record --specs spec/requests
loadwright: recording requests from spec/requests
loadwright: recorded 2 request(s) to tmp/loadwright/recorded-requests.json
  now run: bundle exec loadwright run --dry-run
```

This **runs your specs** and watches what they send — it does not parse them. A
parser silently misses every request built through a helper, a shared example, or a
loop, and the misses are invisible. Executing them has no such failure mode.

It is a separate command because running your test suite is a big, slow,
side-effecting thing to do, and should never happen as an implicit consequence of
asking for a load test. A failing spec still contributes its recording — the request
was captured before the assertion ran.

Recording is how path parameters get resolved. Before recording, an endpoint like
`GET /api/v1/authors/{id}` is reported `inconclusive — path parameters could not be
resolved to real records`. Afterwards it is measured normally. Sending a
placeholder id from an OpenAPI example would just 404 against a freshly-seeded
database, so Loadwright declines to guess.

---

## FactoryBot setup

`factory_map` tells Loadwright what to create so that endpoints have data to return.

```ruby
config.factory_map = {
  "post" => { factory: :post, trait: :with_comments },
  "author" => { factory: :author }
}
```

The key is the resource name as it appears in the path; the value names the factory
and any trait. At each scale factor, Loadwright creates that many records in
batches, tracks every id it created, and deletes exactly those ids afterwards.

**Your factories need `sequence` for unique columns.** If a factory produces a
duplicate value on a uniquely-indexed column, Loadwright reports the collision and
tells you which factory and field to fix:

```
loadwright: SEEDING FAILED for tag (factory :tag)
  created 0 of 30 before failing
  uniqueness collision: Validation failed: Name has already been taken

add a sequence to the :tag factory:
  factory :tag do
    sequence(:name) { |n| "name-#{n}" }
  end

Loadwright will not work around this by generating values itself — that would produce data
that does not match how your app is actually used. This resource is skipped; endpoints that
depend on it will be reported inconclusive rather than healthy.
```

It does **not** invent a unique value to route around it. Auto-generated values
produce data that does not resemble how the app is actually used, and then the
measurements are about that fake data instead of your app.

If seeded records exist but an endpoint still returns `[]`, the factory is probably
not matching the endpoint's scope — the records exist but fall outside its `where`.
Loadwright warns about this rather than reporting a fast empty response as healthy.

---

## Running it

```console
bundle exec loadwright run --dry-run                       # resolve everything, send nothing
bundle exec loadwright run --execute                       # actually issue requests
bundle exec loadwright run --execute --only '/api/v1/orders'
bundle exec loadwright run --execute --mode http
bundle exec loadwright record --specs spec/requests
bundle exec loadwright runs list
bundle exec loadwright baseline set <run_id>
bundle exec loadwright compare <run_a> <run_b>
bundle exec loadwright compare --baseline
```

Run it from your application's root — it boots the app by loading
`config/environment.rb` from the current directory.

**`--only` is the one to remember for a large app.** The common case is "just test
these three routes", and a full sweep of four hundred endpoints is not how you want
to discover that. It accepts a substring or a regular expression, and it narrows the
report's skipped list too, so the output is about what you asked for.

**Flags**

| Flag | Effect |
|---|---|
| `--dry-run` | Resolve everything, send zero requests. The default. |
| `--execute` | Actually issue requests. |
| `--only PATTERN` | Restrict to matching paths. |
| `--mode in_process\|http` | Override `execution_mode` for this run. Beats the initializer. |
| `--i-understand-the-risk` | Required for any run outside `enabled_environments`. |
| `--specs PATH` | For `record`: the spec directory to run and capture. |
| `--baseline` | For `compare`: compare the latest run against the designated baseline. |

**Exit codes**

| Code | Meaning |
|---|---|
| `0` | The run completed. **Findings may still be present** — read the summary, not the exit code. |
| `1` | Something you asked to fail on was found, or the run aborted partway and its report is partial. |
| `3` | **Refused.** Nothing ran — safety gate, containment, boot failure, or no exercisable endpoints. Never read this as a clean result. |
| `130` | Interrupted. Rows cleaned up, partial report written. |

`inconclusive` endpoints never make the exit code non-zero: an endpoint that could
not be measured is a gap in coverage, not a defect. Which is exactly why exit `0`
does not mean "healthy". The exit code is a convenience for scripting, not the
interface — see [When not to use this](#when-not-to-use-this).

### Comparing runs

```console
$ bundle exec loadwright runs list
20260824-144509-c31d3a  4d565bf   3 healthy / 2 with findings / 3 inconclusive
20260824-144446-be1a6b  4d565bf   3 healthy / 2 with findings / 3 inconclusive

$ bundle exec loadwright baseline set 20260824-144446-be1a6b
baseline set to 20260824-144446-be1a6b (4d565bf)
  measured noise floor: 7.3% (from a second run on the same commit)

$ bundle exec loadwright compare --baseline
# Loadwright comparison

`20260824-144446-be1a6b` → `20260824-144509-c31d3a`

No regressions.

## New findings

None. Nothing broke that was not already broken.
```

The noise floor is *measured*, not assumed: two runs of identical code on the same
commit differ only by noise, so the spread between them is the noise. Without a
second run on the commit, Loadwright says so and falls back to
`regression_threshold_pct` — rather than inventing a figure.

Comparison refuses outright when two runs are not comparable — different resolved
config, a different observed page size, or an incompatible capability set. `compare`
exits **2** in that case, distinct from 1 (regressions found), because treating
"could not compare" as a pass is the exact failure the gate exists to prevent.

---

## Reading the report

HTML is the default and the one to look at; Markdown and JSON render from the same
structure.

### Three endpoint states, not two

This is the concept unique to Loadwright, and the one most likely to trip you up.

| State | Meaning |
|---|---|
| **healthy** | Measured, and every applicable check passed. |
| **has findings** | Measured, and something specific is wrong. |
| **inconclusive** | **Not measured.** No verdict is attached. |

`inconclusive` exists because the alternative is confidently wrong. Consider an
endpoint returning `403` in 4ms having run one query. To a query-counting tool that
is the healthiest endpoint in your API. It is not healthy — it was never exercised.
Same for an endpoint returning `[]` because the seeded records fell outside its
scope.

So every endpoint must prove it did the work before any performance verdict attaches
to it, and the ones that could not are reported separately:

```
| healthy | with findings | inconclusive |
|---:|---:|---:|
| 3 | 2 | 4 |

4 endpoints could not be validly measured. They are **not** counted as passing.
```

Each one names its reason:

```
### `GET /api/v1/admin/stats` — INCONCLUSIVE
**Not measured.** endpoint returned an error status; an error path was measured, not
the endpoint (returned HTTP 403 (expected 200). A uniform 401/403 across endpoints
almost always means auth_token_provider is unset or returning an invalid token.)
No performance verdict is attached. Its absence from the findings list means nothing
was checked — not that nothing is wrong.
```

If you take one thing from this README: **"18 endpoints healthy" is a false summary
when 12 were inconclusive.** Report all three numbers.

### Two sweeps, and why

Loadwright runs two sweeps and holds one axis fixed in each.

**The seed-scale sweep** grows the number of rows in the database. It catches
endpoints whose cost tracks table size — missing pagination, unindexed scans.

**The page-size sweep** holds the data fixed and varies the page size, at
concurrency 1. It catches N+1s that pagination hides completely. A paginated
endpoint returns 25 records whether the table holds 30 rows or 30 million, so its
query count is *perfectly flat* against seeded scale — and a seeded-scale slope
reports it as healthy. Only the returned-record count reveals it.

That is why `/api/v1/authors` in the quickstart shows an `n_plus_one_slope` finding
despite a query count that never moves as the database grows.

Queries-per-returned-record is a single-request property, so the page-size sweep
runs at concurrency 1. Varying both at once would make the slope unattributable.

### Where the time went

```
**Where the time went** — 3.51ms total

| Component | Time | Share |
|---|---|---|
| database | 0.33ms | 9.3% |
| view / serialisation | 0.02ms | 0.5% |
| everything else | 3.17ms | 90.2% |
```

A flat query count does not mean an endpoint is fast — one unindexed query can
dominate everything. Both signals are in the report and neither substitutes for the
other.

Every report carries a containment disclosure, because it changes what the numbers
mean:

> _These latency figures are lower than production reality: mail was captured rather
> than delivered, so SMTP time is absent. Outbound HTTP was blocked, so any time the
> app would have spent calling a third party is absent entirely — real-world latency
> will be higher. The missing time appears in no component, not even `other`._

---

## Tuning contention handling

Loadwright generates concurrent load, which can make a database slow for everyone
using it. It detects that, retreats, and never attempts to resolve it.

The ladder: detect degradation → back off with exponential delay and jitter →
quarantine the endpoint → cool down → move on. If contention keeps recurring, the
run aborts. At no point does it terminate a session.

Pick a profile rather than tuning fifteen keys:

| Profile | For | Trades away |
|---|---|---|
| `:conservative` | A shared development database with colleagues in it | Concurrency capped at 5, 1s lock timeout, long cooldowns. Prefers a useless run over any disruption. |
| `:balanced` | A local database you own. **The default.** | Nothing; these are the documented defaults. |
| `:aggressive` | A throwaway or containerised database | Longer timeouts, higher degradation tolerance, short cooldowns. Still retreats; still never kills sessions. |

```ruby
config.contention_profile = :conservative
```

A profile only sets keys you did not set yourself, and the report records which
values came from the preset.

**The interaction to know about:** contention errors are excluded from the circuit
breaker's error rate. If they were not, a busy database would trip the breaker and
the run would report your app as broken. So do **not** raise
`max_error_rate_before_abort` to work around contention — it is the wrong knob, and
it loosens a safety threshold for no benefit. Use `:conservative` instead.

Blocking held by a session that is not one of ours produces `inconclusive`, not a
finding. Your endpoint is not responsible for someone else's lock.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Every endpoint is `inconclusive` with a 401/403 | `auth_token_provider` is unset or returns an invalid token | Set it. This is the number-one first-run failure. |
| Run refuses immediately, exit 3, "not in enabled_environments" | The environment gate is doing its job | Run in `development` or `test`. Do not reach for `allow_production`. |
| Run refuses immediately, "the application raised while booting" | Your app cannot boot | Reproduce with `bundle exec rails runner 1`; it is not a Loadwright problem. |
| `no config/environment.rb` | Wrong working directory | Run from the Rails app root. |
| Run aborts on the baseline health check | The database was already unhealthy before any load | Something else is hammering it. Wait, or use `:conservative`. |
| Endpoints return `200` but empty arrays | Factories do not match the endpoint's scope | Records exist but fall outside its `where`. Fix `factory_map` or add a trait. |
| No N+1 found on an endpoint you know is bad | Pagination blind spot | Confirm `page_size_parameters` names the parameter your API uses, and that `scale_factors` exceed your page size. |
| The run takes forever | Backoff budget, or too large a matrix | The dry run prints both. Reduce `scale_factors` × `concurrency_levels` × `requests_per_endpoint_per_level`. |
| Production boot crashes with `NameError` after installing | The `if defined?(Loadwright)` guard was removed | Put it back. |
| Seeding fails on a duplicate value | A factory needs a `sequence` | The error names the factory and column. |
| `compare` exits 2 | The runs are not comparable | It says which dimension diverged. Re-run one side under matching config. |
| Concurrency findings are missing | You are in `:in_process` | Expected — there is no server thread pool. Use `--mode http`. |

---

## When not to use this

Honestly:

- **For CI gating, use [`n_plus_one_control`][npoc].** Loadwright is exploratory and
  local. It can tell you *what* to assert; it is not the assertion. Its exit code is
  a scripting convenience, and `inconclusive` endpoints deliberately do not fail it.
- **For continuous dev-time detection, use [Bullet][bullet] or
  [Prosopite][prosopite].** They watch every request you make while developing.
  Loadwright is something you run deliberately.
- **For production reality, use an APM** (Scout, AppSignal, Datadog, Skylight).
  Loadwright has no concept of real traffic, real data distributions, or real cache
  states.
- **For capacity planning, use [k6][k6], [vegeta][vegeta], or [wrk][wrk].** The
  concurrency Loadwright drives is enough to surface N+1s, pool pressure, and memory
  bloat on a laptop. It is not enough to model production scale, and it is not
  trying to be.
- **For GraphQL, yes** — operations are discovered, measured, page-size swept, and
  attributed to the resolver that issued the query. See [GraphQL](#graphql).
  Subscriptions are skipped: they are not answered over a plain HTTP POST.
- **If your app uses multiple databases or read replicas**, pool tracking assumes a
  single pool and will under-report.

[k6]: https://k6.io
[vegeta]: https://github.com/tsenart/vegeta
[wrk]: https://github.com/wg/wrk

---

## FAQ

**Will this trash my development database?**
No. Cleanup deletes only the rows Loadwright created, tracked by primary key. It
never truncates a table.

**What if I Ctrl-C halfway through?**
That is a supported way to stop. Signals are trapped: requests stop, any booted
server is torn down, seeded rows are deleted, and a partial report is written and
marked partial. Exit code 130.

**Can I run it against staging?**
Only through the full four-layer gate, and think hard first. If staging shares a
database with anything you care about, the answer should be no.

**Why does it say `inconclusive` instead of just skipping the endpoint?**
Because an endpoint missing from the report and an endpoint that could not be tested
look identical to a reader, and the first reads as coverage the run did not have.

**Why are there no p99 numbers?**
25 samples cannot support a 99th percentile. Percentiles the sample cannot support
are omitted rather than printed as noise. Raise
`requests_per_endpoint_per_level` if you need them.

**Does it work with MySQL?**
Yes. Postgres gets the most (lock introspection, `pg_stat_statements`, richest
EXPLAIN); MySQL and SQLite degrade gracefully, and the report names what was
unavailable and why.

**Does it send my data anywhere?**
No. No telemetry, no version checks. Reports are local files. SQL bind values,
filtered parameters, and matching headers are redacted at collection time, so they
never reach the persisted run record either. Response bodies are excluded by
default.

---

## Examples

Complete, copy-pasteable initializers in [`examples/`](examples):

| Example | For |
|---|---|
| [`minimal/`](examples/minimal) | Smallest working config — routes-only, no factories, defaults everywhere |
| [`openapi_driven/`](examples/openapi_driven) | Full OpenAPI setup with response schema validation |
| [`integration_spec_driven/`](examples/integration_spec_driven) | Recording mode, for apps with no OpenAPI document |
| [`factory_heavy/`](examples/factory_heavy) | Complex `factory_map` — traits, associations, nested resources |
| [`paginated_api/`](examples/paginated_api) | Page-size sweep, and the N+1 seeded-scale alone misses |
| [`http_mode/`](examples/http_mode) | `:http` execution — real Puma, real concurrency, pool findings |
| [`shared_dev_database/`](examples/shared_dev_database) | The `:conservative` preset, for teams sharing a database |
| [`mysql/`](examples/mysql) | Non-Postgres setup and what degrades |
| [`large_monolith/`](examples/large_monolith) | Path filtering and subset runs for hundreds of endpoints |
| [`mutating_endpoints/`](examples/mutating_endpoints) | The `allow_mutating_requests` opt-in, and its risks |
| [`sample_app/`](examples/sample_app) | A live Rails API with deliberate flaws, used by the gem's own tests |

---

## Contributing

**A note on the comments.** The source cites design documents by name —
`production-safety.md`, `response-analysis.md`, `CLAUDE.md section 2`, and others.
Those are internal design notes, not published with the gem, so don't go looking for
them in this repository. Nothing is hidden by their absence: each citation is a
pointer to *why* a decision was made, and the reasoning itself is written out in the
comment around it. The name is provenance, not a dependency.

```console
$ bundle install
$ bundle exec rake spec:seeds      # the suite, under five seeds
$ bundle exec rake mutation_audit  # breaks each safety behaviour, confirms its spec goes red
```

`rake spec:seeds` rather than plain `rspec` is not belt-and-braces:
`examples/sample_app` boots a real Rails app into the suite's own process, so any
example whose premise is "Rails is not loaded" passes or fails by order. That once
silently disabled 22 of the safety guard's examples, including every "refuses to run
in production" case.

A green suite does not prove the safety behaviours are still enforced, which is what
the mutation audit is for. Run it after touching anything safety-critical.

## License

[MIT](LICENSE.txt).

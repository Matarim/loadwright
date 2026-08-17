# Discovery, Seeding & Load Engine — Design Reference

> **Status: specification for software that does not exist yet.** Nothing
> described in this document has been built. Every statement here defines
> *intended* behavior, not current behavior — read it as a build order, not
> as documentation of a working system. When implementation diverges from
> this document, update the document in the same commit.


## Part 1: Discovery — two sources, merged

Loadwright needs to know, for every endpoint: path, verb, required params,
a valid example request body, and (ideally) expected response shape. Two
sources feed this, and they're complementary rather than redundant.

### Source A — OpenAPI/Swagger document

Parse `config.openapi_spec_paths` (via a maintained parser gem, e.g.
`openapi3_parser` — don't hand-roll YAML/JSON schema walking). For each
`path` + `operation`, produce a normalized `Loadwright::Endpoint`:

```ruby
Endpoint.new(
  path: "/api/v1/posts/{id}/comments",
  verb: :post,
  source: :openapi,
  request_schema: {...},        # JSON schema for the body
  example_request: {...},       # from the spec's `example`/`examples`, if present
  path_params: [:id],
  mutating: true,
)
```

If the schema has no example, generate one from the schema itself (type-
appropriate placeholder values) — but prefer a real example whenever the
doc provides one; synthetic values are a fallback, not the primary path.

### Source B — Integration spec recording (not static parsing)

**Do not** write a parser that statically reads arbitrary RSpec files
looking for `get "/foo"` calls. It's fragily coupled to how each team
happens to write specs (shared examples, helper methods, request builders
all break naive parsing) and it will silently under-discover.

Instead: **record real requests as they happen.** Provide a runner (e.g.
`bundle exec loadwright record --specs spec/requests`) that:

1. Boots the app in `test` environment.
2. Wraps `ActionDispatch::Integration::Session#process` (or the equivalent
   entry point used by `get`/`post`/`put`/`patch`/`delete` in request
   specs) with instrumentation that captures verb, path, params, headers,
   and the response — without changing behavior.
3. Runs the specs under `config.integration_spec_paths` normally.
4. Every request the suite actually made — because it's already proven to
   produce a valid response in that spec — becomes a `Loadwright::Endpoint`
   with `source: :integration_spec`.

This is strictly more robust than parsing, because it uses requests the
team has already demonstrated are valid, including ones with complex
nested params that an OpenAPI doc might not fully capture (or might be out
of sync with).

### Merge strategy

- Key endpoints by `(path_template, verb)`.
- If both sources produced an endpoint for the same key, prefer the
  integration-spec version's example request/params (higher fidelity,
  proven-valid) but keep the OpenAPI version's declared schema for
  reference/validation in the report.
- If only one source has it, use that one.
- Anything from `config.route_discovery` (raw Rails routes) fills in
  remaining gaps with no example data — flag these clearly in the report
  as "discovered but no example available; skipped" rather than guessing.

### Path parameter resolution — required, not optional

`GET /posts/{id}/comments` needs a real `id`. OpenAPI examples typically
carry placeholder IDs (`1`, `"string"`, `abc-123`) that 404 against a
freshly-seeded database. Without resolution, most nested endpoints fail
the response validity gate and the entire run reports `inconclusive` —
this is the most likely way a first real-world run produces nothing
useful.

Resolution order for each path param:

1. **A seeded record's real ID.** If `config.factory_map` covers the
   resource named in the path segment, use an ID from the records
   Loadwright just created. This is the primary path and should cover most
   endpoints.
2. **An ID captured during integration-spec recording**, since those
   requests demonstrably worked.
3. **An explicit override** from `config.path_param_overrides`, keyed by
   path template, for anything the first two can't infer (slugs, UUIDs,
   composite keys, external identifiers).
4. **The OpenAPI example**, last, since it's least likely to correspond to
   real data.

If none resolve, skip the endpoint and report it as "path parameters could
not be resolved" with the specific param named — never send a request with
a placeholder ID and then report the resulting 404 as a performance
result.

Rotate IDs across requests rather than hammering one record repeatedly:
a single hot row produces unrealistic cache behavior and can create
row-lock contention that doesn't reflect real traffic.

## Part 2: FactoryBot seeding at scale

For each `scale_factor` in `config.scale_factors`, before hitting the
endpoints that depend on a given resource, seed data for it via
`config.factory_map`:

```ruby
FactoryBot.create_list(:post, scale_factor, :with_comments)
```

### Uniqueness — lean on the app's own factories, don't route around them

Real apps typically already handle uniqueness in their factories via
FactoryBot's `sequence`:

```ruby
factory :user do
  sequence(:email) { |n| "user#{n}@example.com" }
end
```

Loadwright's seeder should **just call `create_list` and let that do its
job.** If it raises `ActiveRecord::RecordInvalid` (or similar) due to a
uniqueness constraint, that means the factory itself doesn't have a
sequence for the colliding field — and the correct behavior is:

1. Catch the error.
2. Report exactly which factory and field collided, with a suggested fix
   (add a `sequence(:field_name)`), in both the terminal output and the
   generated report.
3. Skip further seeding for that resource at that scale factor rather than
   retrying with silently-mutated data.

`config.unique_field_generator` exists only as a documented escape hatch
for resources with **no factory at all** that still need some seed data —
it should not be the first thing reached for.

### Batching and contention

Seed in batches of `config.seed_batch_size` with a health check between
batches rather than one giant transaction — `create_list(:post, 200)` with
callbacks, counter caches, or search-index hooks can lock the table or
exhaust the pool all by itself. Seeding runs under the same resource guard
as request execution; see `references/resource-contention.md` Part 4.

### Cleanup

Respect `config.seed_cleanup_strategy`:
- `:delete_created_rows` (default) — track the IDs Loadwright inserted and
  delete only those, in an `ensure` so it happens even on abort.
  **Never `TRUNCATE`.** A developer's local database contains data they
  care about; wiping their tables because they ran a diagnostic tool is an
  unacceptable outcome.
- `:transactional_rollback` — wrap the run in a transaction and roll back.
  Faster, but note in the report that connection-pool findings are less
  trustworthy under this strategy, since the test isn't exercising
  multiple real connections the way production would.
  **Unavailable in `:http` mode** — the app runs in a separate process and
  won't see the harness's open transaction. Selecting it there is a config
  error that must be caught at startup with a clear message, not a
  mysterious empty-database failure mid-run.
- `:leave` — do nothing; useful when a developer wants to inspect the
  seeded state afterward.

Cleanup itself runs under `config.lock_timeout_ms` — a cleanup that hangs
holding locks is worse than the test that preceded it.

## Part 3: The load engine — scale × concurrency matrix

For each endpoint, for each `scale_factor`, for each `concurrency_level` in
`config.concurrency_levels`, fire `config.requests_per_endpoint_per_level`
requests (after `config.warmup_requests` discarded warmup requests) and
record, per request: latency, query count, distinct query fingerprints,
memory allocated, connection pool stats at request start/end.

### The "smart" part — N+1 detection by slope, not just pattern-matching

Literal duplicate-SQL-pattern detection (what Bullet/Prosopite do) is
still valuable and should run too (`config.detect_n_plus_one`) — reuse
that technique via `ActiveSupport::Notifications` on `sql.active_record`,
comparing call stack + query fingerprint the way Prosopite does.

But the load engine adds a second, complementary signal that neither
Bullet nor Prosopite has, because they don't control data volume: **since
Loadwright seeds at multiple known scale factors, it can plot query count
against scale factor directly.** A flat line (query count roughly constant
regardless of scale) is healthy. A line that grows roughly linearly with
scale factor is an N+1 signature — even in cases where the literal
duplicate-query check produces a false negative (e.g. queries that differ
slightly in a way that defeats fingerprint matching, but still one-per-row).

Report both signals side by side per endpoint rather than collapsing them
into one verdict — they catch different failure modes and disagreement
between them is itself informative.

**Important correction — read `references/response-analysis.md` Part 2
before implementing this.** Slope measured against *seeded* scale factor
has a blind spot: a paginated endpoint returns the same 25 records whether
you seed 10 rows or 10,000, so its query count stays flat and the slope
looks perfect even when it has a severe N+1 on the page it returns. Slope
must therefore be computed against **returned record count**, with page-size
parameters swept to vary it. Endpoints where result size can't be varied
at all get flagged as "N+1 slope not measurable" rather than "flat."

### The query cache will hide N+1s if you let it

ActiveRecord's query cache dedupes identical queries within a single
request. A textbook N+1 — the same `SELECT ... WHERE id = ?` fired per row
— can therefore appear as a *single* query, producing a confident false
negative on precisely the pattern this tool exists to find. Prosopite
handles this explicitly and so must we.

`config.disable_query_cache_during_run` (default `true`) turns it off for
the duration. When it's left on, every N+1 finding must be labelled as
potentially undercounted, because it is.

Note the tradeoff honestly in the report: with the cache disabled, query
counts are truthful about code structure but latency is slightly
pessimistic relative to production, where the cache is active.

### Circuit breaker integration

The engine checks `config.max_error_rate_before_abort` continuously as it
runs the matrix (see `production-safety.md`) and stops issuing new
requests the moment the threshold is crossed, marking remaining
scale/concurrency combinations as "skipped — circuit breaker" in the
report rather than silently omitting them.

### Resource guard integration

The circuit breaker handles *errors*. The resource guard handles
*contention*, which often produces no errors at all — just queuing. They
are separate mechanisms and both must be wired in; see
`references/resource-contention.md` for the full ladder.

Two engine-level requirements that come from the guard:

- Every cell of the matrix records the concurrency level it **actually ran
  at**, which may be lower than requested if the guard stepped it down.
  Never present a stepped-down result as though it ran at the requested
  level.
- A quarantined endpoint is a distinct outcome from a clean one. The
  engine must emit `quarantined` (with the evidence) rather than simply
  omitting the endpoint or recording it as passing.

Baseline latency per endpoint is measured at concurrency level 1 *before*
ramping, because the guard's Tier 3 degradation check needs it. That
ordering is a hard dependency, not an optimization.

# examples/sample_app — the live fixture

A deliberately small, deliberately flawed Rails API. It exists so every analysis
path in Loadwright has a **real endpoint with a real query pattern against a real
database** to run against, rather than a mock. A mock of a query pattern is a mock
of the thing under test.

**The bugs in this app are load bearing. Do not fix them.** Each one exists to make
a specific finding provable, and each is annotated in the source with which.

## What's wrong with it, on purpose

| Endpoint | Planted defect | What it proves |
|---|---|---|
| `GET /api/v1/posts` | Unpaginated **and** N+1 on `comments.count` | Two independent findings in one endpoint. Payload growth catches the missing pagination — no query-count signal ever will, since loading 10k rows can be one efficient query. The seeded-scale slope catches the N+1, *because* the endpoint is unpaginated. |
| `GET /api/v1/authors` | Correctly paginated **and** N+1 on `posts.count` | **The regression fixture.** Query count is flat against seeded scale, so a seeded-scale slope calls it perfectly healthy. Only the returned-record-count slope — swept via `per_page` — sees it. This is `response-analysis.md` Part 2's blind spot, live. |
| `GET /api/v1/tags` | Eager-loads `posts: :comments`, serialises neither | Over-fetch. Note `posts.any?` is a *real* use of the loaded data, which is why this must be a hint and never a finding. |
| `GET /api/v1/admin/stats` | Always `403`, zero queries, ~2ms | **The most important fixture here.** To a query-counting tool this is the healthiest endpoint in the API and ranks top of any "clean" list. The validity gate must make it `inconclusive`. |
| `GET /api/v1/posts/{post_id}/comments` | Nothing — it is correct | A run that finds problems everywhere is as untrustworthy as one that finds them nowhere. |
| `GET /api/v1/authors/by-slug/{slug}` | Non-inferrable path segment | The case `config.path_param_overrides` exists for. |
| `factory :tag` | No `sequence` on a unique column | The collision path. Loadwright must name the factory and field with a suggested `sequence(...)` fix and skip the resource — never silently generate a unique value, which would produce data that does not match how the app is used. |
| `factory :post, :draft` | `published: false` | Seeding these and hitting `posts#index` (scoped to published) returns `[]`, which must be `inconclusive` for "seeded records did not match the endpoint's scope". |

## Observed behaviour, for reference

With 40 posts (3 comments each) and 5 tags seeded:

```
/api/v1/posts                      status=200 queries=41  records=40
/api/v1/authors?per_page=5         status=200 queries=6   records=5
/api/v1/authors?per_page=25        status=200 queries=26  records=25
/api/v1/tags                       status=200 queries=2   records=5
/api/v1/admin/stats                status=403 queries=0
/api/v1/posts/4/comments           status=200 queries=2   records=3
```

The `authors` pair is the whole point: 5 records → 6 queries, 25 records → 26
queries. Query count tracks *returned* records, and would sit flat at 26 no matter
how many authors the table held.

## Running it

```sh
# In-process (what the gem's own specs mostly use)
RAILS_ENV=test bundle exec ruby -r./examples/sample_app/config/environment -e 'puts Post.count'

# As a real server, for :http mode
cd examples/sample_app && RAILS_ENV=test bundle exec puma -p 3001
```

The database is SQLite on a **file**, not in-memory. That is not laziness: `:http`
mode boots the app in a separate process, and an in-memory database is invisible
across processes — seeded rows would exist for the harness and not for the app under
test, so every endpoint would honestly return `[]` and the whole run would come back
`inconclusive` for a reason unrelated to the app.

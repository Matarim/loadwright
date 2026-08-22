# Minimal

The smallest configuration that produces a useful run. Every value here is
already the default — the file exists to show you what the defaults *are*.

## Who this is for

You are evaluating Loadwright. You have a Rails API, no OpenAPI document, no
request specs you want to record, and about sixty seconds of patience.

## What you get

Route-only discovery over your GET endpoints, at a single scale factor and a
single concurrency level, against whatever data your development database
already contains.

That is enough to find:

- an N+1 that fires on data you already have
- an endpoint returning an unbounded collection
- an endpoint that is simply slow

## What it trades away

**Nothing is seeded.** Query counts are measured against your existing dev
data, so:

- On a *populated* database, a textbook N+1 shows up immediately.
- On an *empty* one, an endpoint with no rows returns nothing and cannot
  show a per-row query. The report will say the endpoint was measured and
  found nothing — which is true, and not the same as "your endpoint is
  fine".

**The scale sweep means nothing.** With one scale factor there is no slope to
measure, so `missing_pagination` is reported as `not_applicable` rather than
checked. Add a second scale factor and a `factory_map` and it becomes a real
signal — see [`../factory_heavy`](../factory_heavy).

**Route-only discovery is verb-limited.** It knows a path and a verb and
nothing about what a valid request body looks like, so it is GET-friendly and
little else. See [`../openapi_driven`](../openapi_driven) or
[`../integration_spec_driven`](../integration_spec_driven).

## Running it

```
bundle exec loadwright run --dry-run     # resolve everything, send nothing
bundle exec loadwright run --execute
```

Always dry-run first. It prints the endpoint list, the mutating-request
count, the estimated duration, and the worst-case backoff budget before
anything is sent.

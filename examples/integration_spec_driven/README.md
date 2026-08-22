# Integration-spec driven

Discovery by **recording** your request specs, not by parsing them.

## Who this is for

You have a decent request-spec suite and no OpenAPI document. Your specs
already know how to construct a valid, authenticated request to every
endpoint that matters — including the awkward ones with nested ids and
required headers.

## Recording, not parsing

This is the design decision that makes the source trustworthy.

A hand-rolled AST walker over arbitrary RSpec files is fragile and will
silently miss valid requests. "Silently missed" is the worst available
failure here: an endpoint that was never tested is reported as *absent*
rather than as *skipped*, so an API that is half-covered reads exactly like
an API that is clean.

Recording sidesteps the whole problem. Loadwright runs your specs and watches
what the app actually received — real path, real params, real headers, real
ids. There is nothing to infer.

## Setup

```
bundle exec loadwright record --specs spec/requests
bundle exec loadwright run --dry-run
bundle exec loadwright run --execute
```

The recording step runs your specs once. Budget for that: on a large suite it
is the slowest part of setup, and it is a one-time cost per change to your
routes.

## What it trades away

**Completeness is your suite's completeness.** An endpoint with no spec is
invisible to this source. That is why `route_discovery` stays on underneath —
routes contribute the endpoints your specs never touched, and the report says
which source each endpoint came from, so a gap is visible rather than absent.

**No schema validation.** Recording tells Loadwright what a valid *request*
looks like. It says nothing about what a valid *response* looks like, so
`require_schema_valid_response` has nothing to check against. If you want the
response contract checked too, you want an OpenAPI document — see
[`../openapi_driven`](../openapi_driven).

**Recorded requests carry real headers, including auth.** That is usually
what you want, and it is also why the recorded fixture deserves the same care
as any other file holding a token. It is redacted on the way in, and bind
values never reach it.

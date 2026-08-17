# The pagination blind spot

> **Placeholder — not written yet.** This directory exists so the example
> set does not get forgotten. See `references/readme-and-examples.md` for
> the full table.

Page-size sweep configuration, and the two-sweep matrix shape.

## What this will demonstrate

- The case where seeded-scale slope alone misses an N+1 entirely, because the endpoint returns one page however much you seed
- Why the seed-scale and page-size sweeps hold one axis fixed each

## What this will contain

- `loadwright.rb` — a complete, commented initializer for this scenario
- notes on the tradeoffs it makes and who it is for

These examples double as integration-test fixtures, so once written they
have to stay valid.

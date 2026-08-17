# Non-Postgres setup

> **Placeholder — not written yet.** This directory exists so the example
> set does not get forgotten. See `references/readme-and-examples.md` for
> the full table.

Running against MySQL.

## What this will demonstrate

- What degrades gracefully: lock introspection, pg_stat_statements, EXPLAIN detail
- How the report states the reduced signal set rather than staying silent about it

## What this will contain

- `loadwright.rb` — a complete, commented initializer for this scenario
- notes on the tradeoffs it makes and who it is for

These examples double as integration-test fixtures, so once written they
have to stay valid.

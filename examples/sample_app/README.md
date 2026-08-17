# The gem's own end-to-end fixture

> **Placeholder — not written yet.** This directory exists so the example
> set does not get forgotten. See `references/readme-and-examples.md` for
> the full table.

A minimal Rails API application that Loadwright's own test suite runs against.

## What this will demonstrate

- One N+1, one unpaginated endpoint, one over-fetching endpoint, and one endpoint that 403s, so every analysis path has a live fixture
- Both execution modes exercised end-to-end against something real

## What this will contain

- `loadwright.rb` — a complete, commented initializer for this scenario
- notes on the tradeoffs it makes and who it is for

These examples double as integration-test fixtures, so once written they
have to stay valid.

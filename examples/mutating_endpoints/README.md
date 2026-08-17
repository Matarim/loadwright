# The allow_mutating_requests opt-in

> **Placeholder — not written yet.** This directory exists so the example
> set does not get forgotten. See `references/readme-and-examples.md` for
> the full table.

POST/PUT/PATCH/DELETE traffic under load, and the risks that come with it.

## What this will demonstrate

- Side-effect containment for mail, jobs, and outbound HTTP
- Why mutating endpoints confound their own measurement — request 500 runs against 499 more rows than request 1

## What this will contain

- `loadwright.rb` — a complete, commented initializer for this scenario
- notes on the tradeoffs it makes and who it is for

These examples double as integration-test fixtures, so once written they
have to stay valid.

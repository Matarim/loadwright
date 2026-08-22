# Large monolith

Subset runs, because the full matrix is measured in hours.

## The arithmetic

```
400 endpoints x 4 scale factors x 3 concurrency levels x 25 requests
= 120,000 requests, before warmups
```

At a generous 25ms each that is roughly fifty minutes of wall time, and that
is before any backoff. Nobody should discover a four-hour run by waiting
through it.

Loadwright computes the estimated duration **and the worst-case backoff
budget** before starting, prints both, and prompts for confirmation above
`long_run_confirmation_threshold_minutes`. This example is about not needing
that prompt.

## Filtering

`included_paths` is an **allowlist**. When it is set, nothing outside it is
discovered at all — which is what makes a 400-endpoint app tractable.

`excluded_paths` is applied afterwards, for the surfaces you never want:
`/rails/`, `/admin/`, `/internal/`, and `/health` (which being hammered can
page somebody).

**Everything filtered out appears in the report's skipped appendix, with the
reason.** That is not bookkeeping. A filtered run that presented itself as a
whole-API result would be the most misleading output this tool could produce,
so nothing silently disappears.

## The one-off case

The common request is "just test these three routes", and that should not
require editing config:

```
bundle exec loadwright run --execute --only '/api/v1/orders'
```

Use `--only` for exploration and `included_paths` for the set you check
regularly.

## Trimming the matrix

- **Two scale factors** still give a slope. Four give a smoother one and cost
  twice as much.
- **Two concurrency levels** rarely tell you less than three on a laptop.
- Seed only what the allowlisted endpoints touch. A `factory_map` covering
  the whole schema is the other way a large app makes runs slow — every scale
  step seeds every mapped resource, whether or not anything requests it.

## Working through a big API

Rather than one enormous run:

1. Pick a subsystem. Run it. Set it as the baseline:
   `bundle exec loadwright baseline set <run_id>`
2. Run it a second time on the same commit so the noise floor is *measured*
   rather than assumed.
3. Move to the next subsystem.
4. Re-run and `compare` when you change something.

`run_history_limit` is lowered here because an app you run against often
accumulates records fast, and they live under `tmp/`.

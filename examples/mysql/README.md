# MySQL

What works, what degrades, and what says so rather than guessing.

## The principle

Most of Loadwright is adapter-agnostic. The parts that are not degrade to
**`unavailable`, with a reason** — never to zero.

That distinction is the whole point. A zero reads as "measured, and fine",
and an adapter limitation rendered as a zero is a confidently wrong all-clear
about your database.

## Unchanged on MySQL

- query counts, and N+1 by both pattern-match and slope
- payload growth and the missing-pagination signal
- the response validity gate and schema validation
- the db / view / GC / other time breakdown
- latency statistics and percentile validity
- pool-vs-server-threads sizing

## What degrades

| Signal | On MySQL | Versus Postgres |
|---|---|---|
| `EXPLAIN` | works, via `EXPLAIN FORMAT=JSON` | access type and filesort; no per-node timings or buffers |
| lock introspection | works, via `information_schema.innodb_trx` | less detail than `pg_locks` |
| `pg_stat_statements` | does not exist | reported **not applicable** |

### Sequential scans

MySQL reports a full table scan as `access_type: "ALL"` with
`rows_examined_per_scan`. Loadwright applies `seq_scan_row_threshold` to that
count, so the finding means the same thing it does on Postgres: *this is one
query, so query counting will never show it, and it gets linearly slower as
the table grows.*

What you do not get is the estimated-versus-actual row divergence that
Postgres exposes, which is how the stale-statistics finding is derived. That
finding is simply absent here rather than guessed at.

### Not applicable is not a gap

`track_pg_stat_statements = false` produces **`not_applicable`**, not
`unavailable`.

The difference matters to the outcome state. `unavailable` means Loadwright
tried and could not answer, which is a real coverage gap and can make an
endpoint `inconclusive`. `not_applicable` means it was never attempted —
because the subsystem does not apply here — and that is not a hole this run
left.

Without that distinction, every endpoint on every MySQL app would read
`inconclusive` for a Postgres-only feature.

## The rounding wrinkle

MySQL's `innodb_lock_wait_timeout` is **seconds-granular**. Loadwright rounds
`lock_timeout_ms` *up* when applying it, so `3000` becomes 3s and `1500`
becomes 2s rather than 1. Rounding down would apply a tighter timeout than
you asked for.

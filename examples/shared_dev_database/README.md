# Shared development database

The `:conservative` preset, for a database other people are using.

## Who this is for

A team on a shared development or staging database. Your load test is not the
only thing running, and the cost of getting it wrong is not your own
afternoon — it is everyone else's.

## The rule that governs everything here

**Loadwright retreats from contention. It never attempts to resolve it.**

It will back off, quarantine an endpoint, and abort a run. It will *never*
terminate a database session, cancel a query, or kill a connection. No
configuration option enables that, and none will be added — a tool that
resolves contention by killing sessions is a tool that kills your colleague's
migration.

If you find yourself wanting a `--force` flag, the answer is to reduce load.

## Ours versus theirs

Contention caused by a session that is **not ours** produces an
`inconclusive` endpoint, not a finding.

That distinction is the whole reason the health poller identifies its own
connections. Blaming an endpoint for a lock somebody else is holding is a
confidently wrong answer, and it sends a developer to optimise code that is
fine.

The report separates the two:

- **quarantined** — our own load caused sustained contention; the endpoint
  was abandoned after the backoff ladder
- **externally blocked** — someone else's session; nothing here is
  attributable to the endpoint

## What `:conservative` changes

| Key | Conservative | Default |
|---|---:|---:|
| `lock_timeout_ms` | 1,000 | 3,000 |
| `statement_timeout_ms` | 5,000 | 10,000 |
| `concurrency_levels` | `[1, 5]` | `[1, 5, 20]` |
| `health_poll_interval_ms` | 250 | 500 |
| `degradation_windows_before_backoff` | 2 | 3 |
| `max_backoff_attempts` | 3 | 4 |
| `post_quarantine_cooldown_ms` | 15,000 | 5,000 |
| `max_consecutive_quarantines` | 2 | 3 |

Short timeouts, gentle concurrency, early backoff, quick quarantine.

Anything you set **explicitly** still overrides the preset, whichever order
you write it in — the config tracks where each value came from, and the
report shows the provenance of every resolved key.

## Baseline health

```ruby
config.abort_on_unhealthy_baseline = true
```

Leave this on. On a shared box the baseline check is the difference between
measuring your app and measuring someone else's migration.

## The interaction worth knowing about

Contention errors are **structurally excluded** from the circuit breaker's
error rate. They are counted and reported separately.

So if a run aborts on error rate *and* logged forty contention events, those
are two facts, not one — and raising `max_error_rate_before_abort` will not
help, because the contention was never in the numerator that tripped it.

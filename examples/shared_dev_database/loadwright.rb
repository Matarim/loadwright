# frozen_string_literal: true

# SHARED DEV DATABASE — the :conservative preset, for a database other people are using.
#
# Who this is for: a team on a shared development or staging database. Your load test
# is not the only thing running, and the cost of getting this wrong is not your own
# afternoon — it is everyone else's.
#
# THE RULE THAT GOVERNS EVERYTHING HERE: Loadwright RETREATS from contention and
# never attempts to resolve it. It will back off, quarantine an endpoint, and abort a
# run. It will NEVER terminate a database session, cancel a query, or kill a
# connection — no configuration option enables that, because a tool that resolves
# contention by killing sessions kills your colleague's migration.
#
# If contention was caused by a session that is NOT ours, the affected endpoint is
# reported `inconclusive` rather than as a finding: blaming an endpoint for someone
# else's lock is a confidently wrong answer.
if defined?(Loadwright)
  Loadwright.configure do |config|
    # Short timeouts, gentle concurrency, early backoff, quick quarantine. Anything
    # you set EXPLICITLY still overrides the preset, whichever order you write it in.
    config.contention_profile = :conservative

    # What the preset resolves to, spelled out. You do not need these lines — they
    # are here so you can see what you are getting rather than having to look it up.
    config.lock_timeout_ms = 1_000       # give up on a lock fast; someone else has it
    config.statement_timeout_ms = 5_000
    config.concurrency_levels = [1, 5]   # never 20 on a shared box
    config.health_poll_interval_ms = 250 # notice trouble sooner
    config.degradation_windows_before_backoff = 2
    config.max_backoff_attempts = 3
    config.post_quarantine_cooldown_ms = 15_000
    config.max_consecutive_quarantines = 2

    # ABORT IF THE DATABASE IS ALREADY UNHAPPY. On a shared box the baseline check is
    # the difference between measuring your app and measuring someone else's
    # migration. Leave this on.
    config.abort_on_unhealthy_baseline = true

    # Read-only. On a shared database this is not a default to override lightly.
    config.allow_mutating_requests = false

    # Small sweeps. The goal on a shared box is a signal, not a census.
    config.scale_factors = [10, 50]
    config.requests_per_endpoint_per_level = 25

    config.factory_map = { "post" => { factory: :post } }
  end
end

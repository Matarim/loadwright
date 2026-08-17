# frozen_string_literal: true

# MYSQL — what works, what degrades, and what says so instead of guessing.
#
# Who this is for: a MySQL or MariaDB app. Most of Loadwright is adapter-agnostic;
# the parts that are not degrade to `unavailable` WITH A REASON rather than to zero,
# because a zero reads as "measured, and fine" and that is the one thing this tool
# must never say by accident.
#
# WHAT IS UNCHANGED
#   query counts, N+1 by pattern and by slope, payload growth, response validity,
#   the time breakdown, latency statistics, pool-vs-threads sizing.
#
# WHAT DEGRADES
#   EXPLAIN            works, via EXPLAIN FORMAT=JSON. Fewer signals than Postgres:
#                      access type and filesort, no per-node timings or buffers.
#   lock introspection works, via information_schema.innodb_trx. Less detail than
#                      pg_locks, and it is what tells ours-vs-theirs apart.
#   pg_stat_statements does not exist. Reported not-applicable, not missing.
if defined?(Loadwright)
  Loadwright.configure do |config|
    # Postgres-only, and asking for it on MySQL would report a gap that is not one.
    # `not_applicable` rather than `unavailable`: nothing was attempted, so nothing
    # failed, and the coverage model must not treat it as a hole this run left.
    config.track_pg_stat_statements = false

    # EXPLAIN FORMAT=JSON. Sequential scans surface as access_type "ALL"; sorts
    # surface as using_filesort. Both are real signals; neither carries the row
    # timings Postgres gives you.
    config.run_explain_on_slow_queries = true
    config.explain_top_n_queries = 5
    config.seq_scan_row_threshold = 10_000

    # MySQL's lock wait is seconds-granular, so the millisecond value is rounded UP
    # when applied. 3000ms becomes 3s; 1500ms also becomes 2s rather than 1.
    config.lock_timeout_ms = 3_000
    config.statement_timeout_ms = 10_000

    config.factory_map = { "post" => { factory: :post, trait: :with_comments } }
    config.scale_factors = [10, 100]
    config.concurrency_levels = [1, 5]
    config.requests_per_endpoint_per_level = 25
  end
end

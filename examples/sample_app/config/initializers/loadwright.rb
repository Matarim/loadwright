# frozen_string_literal: true

# The fixture's own Loadwright configuration, used by the CLI end-to-end spec.
#
# `if defined?(Loadwright)` is the guard every generated initializer carries, for the
# reason in CLAUDE.md corollary 1: initializers are evaluated in every environment,
# the gem lives in the :development, :test group, and an unguarded reference to a
# constant that is not there crashes a production boot. This file is also a spec
# subject -- the drift check reads real generated initializers, and this one is the
# only initializer in the repo that a real Rails app actually evaluates.
#
# ===========================================================================
# WHY THE ENV VAR. Everything else in the suite boots this app IN THE SUITE'S OWN
# PROCESS and builds its own `Configuration.new`. If this block ran there too it
# would mutate the global `Loadwright.configuration` for every example that came
# after it, and whether it had done so yet would depend on load order -- which is
# exactly the failure CLAUDE.md's `rake spec:seeds` rule exists to catch, and which
# once silently disabled 22 of the safety guard's examples.
#
# The CLI runs in a subprocess and sets the variable; the in-process suite does not.
# ===========================================================================
if defined?(Loadwright) && ENV["SAMPLE_APP_LOADWRIGHT_CONFIG"]
  Loadwright.configure do |config|
    config.execution_mode = (ENV["SAMPLE_APP_LOADWRIGHT_MODE"] || "in_process").to_sym

    # Both scale factors exceed the authors endpoint's default page size of 25, so
    # its pages are actually full and the seed-scale sweep is genuinely flat. Below
    # that, returned count tracks table size and the sweep has not settled yet.
    config.scale_factors = [30, 90]
    config.page_size_sweep = [5, 25, 50]
    config.concurrency_levels = [1]
    # Enough to support p50, which min_samples_for_percentiles puts at 20. Below it
    # the latency detector correctly reports that it cannot answer and every endpoint
    # goes inconclusive for incomplete coverage.
    config.requests_per_endpoint_per_level = 20
    config.warmup_requests = 1
    # The fixture's queries all run in well under a millisecond, so at the default
    # 100ms threshold nothing would ever be explained and EXPLAIN would never run.
    config.slow_query_threshold_ms = 0
    config.factory_map = { "post" => { factory: :post, trait: :with_comments } }
    config.report_formats = %i[html markdown json]
    # So the CLI end-to-end spec can collect the artifacts somewhere disposable
    # instead of writing them into the fixture's own tree on every suite run.
    report_dir = ENV.fetch("SAMPLE_APP_LOADWRIGHT_REPORT_DIR", nil)
    config.report_output_dir = report_dir if report_dir
  end
end

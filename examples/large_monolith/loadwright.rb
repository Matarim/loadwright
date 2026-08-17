# frozen_string_literal: true

# LARGE MONOLITH — subset runs, because the full matrix is measured in hours.
#
# Who this is for: an app with hundreds of endpoints. The arithmetic is unforgiving:
# 400 endpoints x 4 scale factors x 3 concurrency levels x 25 requests is 120,000
# requests before warmups, and nobody discovers a four-hour run by waiting through it.
#
# Loadwright computes and PRINTS the estimated duration and the worst-case backoff
# budget before starting, and prompts for confirmation above
# long_run_confirmation_threshold_minutes. This file is about not needing that prompt.
#
# THE COMMON CASE IS "JUST TEST THESE THREE ROUTES", and that should be the easy
# thing. `--only` on the command line beats editing config for a one-off:
#
#   bundle exec loadwright run --execute --only '/api/v1/orders'
if defined?(Loadwright)
  Loadwright.configure do |config|
    # An ALLOWLIST. When included_paths is set, nothing outside it is discovered at
    # all — which is what makes a 400-endpoint app tractable. Everything excluded
    # appears in the report's skipped appendix WITH THE REASON, so a filtered run
    # never silently reads as a whole-API clean bill of health.
    config.included_paths = [
      %r{^/api/v1/orders},
      %r{^/api/v1/checkout},
      %r{^/api/v1/inventory}
    ]

    # Applied after the allowlist. Admin and internal surfaces are rarely what you
    # are load-testing, and /health being hammered can page someone.
    config.excluded_paths = [
      %r{^/rails/},
      %r{^/admin/},
      %r{^/internal/},
      %r{^/health}
    ]

    # Trim the matrix itself. Two scale factors still give a slope; three concurrency
    # levels rarely tell you more than two on a laptop.
    config.scale_factors = [10, 200]
    config.concurrency_levels = [1, 10]
    config.requests_per_endpoint_per_level = 25

    # Prompt sooner than the default 10 minutes, since on an app this size the
    # estimate is the number that matters most.
    config.long_run_confirmation_threshold_minutes = 5

    # Seed only what the allowlisted endpoints actually touch. A factory_map covering
    # the whole schema is the other way a large app makes runs slow.
    config.factory_map = {
      "order" => { factory: :order, trait: :with_line_items },
      "product" => { factory: :product }
    }

    # Keep history bounded on an app you run this against often.
    config.run_history_limit = 20
  end
end

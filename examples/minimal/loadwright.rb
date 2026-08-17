# frozen_string_literal: true

# MINIMAL — the smallest thing that produces a useful run.
#
# Who this is for: someone evaluating Loadwright who has no OpenAPI document, no
# request specs worth recording, and no appetite for setup. Everything here is a
# default; the file exists to show you what the defaults ARE, not to change them.
#
# What it trades away: without factories nothing is seeded, so query counts are
# measured against whatever data your development database already holds. That is
# enough to find a textbook N+1 on a populated dev database and not enough to find
# one on an empty one — an endpoint with no rows returns nothing and cannot show a
# per-row query. See factory_heavy/ when you want the scale sweep to mean something.
#
# The `if defined?(Loadwright)` guard is NOT optional. Rails evaluates every
# initializer in every environment, and this gem belongs in the :development, :test
# group — so without the guard, booting production raises NameError and the app does
# not start.
if defined?(Loadwright)
  Loadwright.configure do |config|
    # Rails route introspection only. No OpenAPI parsing, no spec recording.
    # Route-only discovery knows the path and the verb and nothing about what a valid
    # request body looks like, so it is GET-friendly and little else.
    config.route_discovery = true
    config.openapi_spec_paths = []
    config.integration_spec_paths = []

    # Read-only. Mutating verbs are skipped entirely unless you opt in, which is the
    # posture you want before you have read what containment does.
    config.allow_mutating_requests = false

    # Skip the framework's own routes and anything under /admin.
    config.excluded_paths = [%r{^/rails/}, %r{^/admin/}, %r{^/health}]

    # Small enough to finish in under a minute on a laptop. The default is
    # [1, 10, 50, 200], which is the right sweep once you are seeding data.
    config.scale_factors = [1]
    config.concurrency_levels = [1]

    # 25 supports p50 and nothing above it. Loadwright OMITS the percentiles this
    # cannot support rather than printing noise, so you will see p50 and an
    # explanation of what p95 would need.
    config.requests_per_endpoint_per_level = 25
  end
end

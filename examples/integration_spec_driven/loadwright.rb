# frozen_string_literal: true

# INTEGRATION-SPEC DRIVEN — discovery by RECORDING your own specs, not parsing them.
#
# Who this is for: an app with a decent request-spec suite and no OpenAPI document.
# Your specs already know how to construct a valid, authenticated request to every
# endpoint that matters. Loadwright runs them once and watches.
#
# RECORDING, NOT PARSING, and the distinction is the whole design. A hand-rolled AST
# walker over arbitrary RSpec files is fragile and silently misses valid requests —
# and "silently missed" is the worst possible failure here, because an endpoint that
# was never tested is reported as absent rather than as skipped. Recording sees the
# request the app actually received: real path, real params, real headers, real ids.
#
# What it trades away: you have to run your specs once, and the recording is only as
# complete as they are. An endpoint with no spec is invisible to this source, which
# is why route discovery stays on underneath it.
if defined?(Loadwright)
  Loadwright.configure do |config|
    # Where to look. `bundle exec loadwright record --specs spec/requests` runs these
    # and captures what they send.
    config.integration_spec_paths = [
      Rails.root.join("spec/requests"),
      Rails.root.join("spec/integration")
    ]

    config.openapi_spec_paths = []

    # The gap-filler. Route discovery contributes endpoints your specs never touched,
    # so the report can distinguish "tested and clean" from "never exercised".
    config.route_discovery = true

    # Recorded requests carry the headers your specs sent, INCLUDING auth. That is
    # usually what you want and is also why the recorded fixture deserves the same
    # care as any other file holding a token: it is redacted on the way in, and
    # bind values never reach it.
    config.auth_strategy = :bearer_token

    # Recorded ids are the second-best path-parameter source, after ids Loadwright
    # seeded itself. Both beat an OpenAPI `example`, which 404s against fresh data.
    config.factory_map = { "post" => { factory: :post } }

    config.scale_factors = [10, 100]
    config.requests_per_endpoint_per_level = 25
  end
end

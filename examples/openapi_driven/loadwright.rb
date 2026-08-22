# frozen_string_literal: true

# OPENAPI-DRIVEN — discovery and response validation from a schema you already have.
#
# Who this is for: an app with a maintained OpenAPI/Swagger document, usually via
# rswag. This is the richest discovery source: it knows the path, the verb, the
# parameters, and the response schema, which is what makes SCHEMA VALIDATION
# possible at all.
#
# Why schema validation matters more than it sounds: an endpoint returning 200 with
# a body that no longer matches its declared schema has broken its contract, and a
# query-counting tool would call it healthy. Loadwright gates every performance
# verdict on the response first, so a schema-invalid response is `inconclusive` —
# not fast, not slow, not measured.
#
# What it trades away: your document has to be accurate. Loadwright FAILS LOUD on a
# partial parse rather than silently testing the half it understood, because a
# half-parsed document reports the endpoints it missed as absent rather than as
# skipped — and an API that is half-tested reads exactly like an API that is clean.
if defined?(Loadwright)
  Loadwright.configure do |config|
    # rswag's conventional output location. Multiple documents are fine; they are
    # merged, keyed by (path template, verb).
    config.openapi_spec_paths = [Rails.root.join("swagger/v1/swagger.yaml")]

    # Route introspection stays on as a GAP-FILLER only. Anything the document
    # describes wins; routes contribute endpoints the document forgot, and the
    # report says which source each endpoint came from.
    config.route_discovery = true

    # THE PAYOFF. A 200 whose body does not match the declared schema is
    # `inconclusive`, with the validation error, rather than being handed a
    # performance verdict it has not earned.
    config.require_schema_valid_response = true
    config.require_successful_response = true

    # Path parameters resolve from seeded records first, then recorded ids, then
    # your overrides, then the document's `example` value. The document's examples
    # are the LAST resort on purpose: an example id of 1 404s against a freshly
    # seeded database, and a 404 measured at 3ms is the classic false clean.
    config.path_param_overrides = {
      # "/api/v1/tenants/{tenant_id}/reports" => { "tenant_id" => 42 }
    }

    config.factory_map = {
      "post" => { factory: :post },
      "author" => { factory: :author }
    }

    config.scale_factors = [10, 100]
    config.concurrency_levels = [1, 5]
  end
end

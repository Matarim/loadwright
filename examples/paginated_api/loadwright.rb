# frozen_string_literal: true

# PAGINATED API — the case a seeded-scale sweep alone cannot see.
#
# THE BLIND SPOT THIS EXAMPLE EXISTS FOR. An endpoint that paginates returns the same
# 25 records whether the table holds 30 rows or 30,000. Its query count is therefore
# FLAT across every scale factor — and a tool that measures N+1 by slope against
# seeded rows reports it as perfectly healthy while it issues one query per returned
# record on every single request.
#
# This is not a corner case. It is most well-built Rails APIs.
#
# The fix is two sweeps with ONE AXIS FIXED IN EACH:
#
#   SEED-SCALE   vary rows in the table, send NO page-size parameter
#                -> does query COST grow with table size? (indexes, scans)
#
#   PAGE-SIZE    vary the page-size parameter, hold seeded rows at the maximum
#                -> does query COUNT grow with records returned? (the N+1)
#
# Never both at once: if seeded rows and page size both change between cells, a rise
# in query count cannot be attributed to either, and the slope is unattributable
# rather than merely noisy.
if defined?(Loadwright)
  Loadwright.configure do |config|
    # The parameter names your app accepts. The FIRST one is used; an endpoint that
    # ignores it shows up as "unable to vary result size" rather than as flat, which
    # is the distinction that stops a non-paginating endpoint reading as clean.
    config.page_size_parameters = %w[per_page limit page[size] pageSize]

    # The sweep itself. Each value has to be reachable: sweeping 5/25/100 against
    # 30 seeded rows measures the same 30 records three times and draws a flat line
    # that means nothing.
    config.page_size_sweep = [5, 25, 100]

    # SO THE LARGEST PAGE CAN ACTUALLY FILL. This must be at least the biggest value
    # in page_size_sweep, or Loadwright skips the page-size sweep and says why
    # rather than producing a flat line you would read as healthy.
    config.scale_factors = [10, 100, 200]

    config.factory_map = {
      "post" => { factory: :post, trait: :with_comments },
      "author" => { factory: :author, trait: :with_posts }
    }

    # Payload growth against table size is the other half. An endpoint whose response
    # bytes track the table is unpaginated, whatever its query count does — one query
    # can load ten thousand rows.
    config.payload_growth_correlation_threshold = 0.8

    config.requests_per_endpoint_per_level = 25
  end
end

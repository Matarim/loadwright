# frozen_string_literal: true

# FACTORY-HEAVY — a real factory_map, with traits, associations, and the uniqueness
# collision you will hit on your first run.
#
# Who this is for: anyone who wants the scale sweep to mean anything. Without seeded
# data there is no slope, and without a slope the two most valuable findings —
# "query count grows with rows returned" and "payload grows with table size" — are
# reported as not-applicable rather than checked.
#
# THE COLLISION YOU WILL HIT. FactoryBot factories written for unit tests usually
# create one record at a time, so a hardcoded `email { "user@example.com" }` never
# collides. Loadwright creates two hundred, and the unique index fires on the second.
#
# Loadwright does NOT work around this by generating a unique value for you. It
# reports which factory and which field need a `sequence`, and stops. Auto-generating
# would produce data that does not match how your app is actually used, and would
# hide a real gap in your factories behind a tool-specific workaround.
if defined?(Loadwright)
  Loadwright.configure do |config|
    config.factory_bot_enabled = true

    # Keyed by the RESOURCE NAME in the path. `/api/v1/posts` -> "post".
    #
    # `trait` is where associations come from: `:with_comments` on the post factory
    # is what creates the child rows an N+1 needs in order to fire at all. A post
    # with no comments cannot demonstrate a per-comment query.
    config.factory_map = {
      "post" => { factory: :post, trait: :with_comments },
      "author" => { factory: :author },
      "comment" => { factory: :comment },
      "tag" => { factory: :tag }
    }

    # The sweep. Each step seeds the DIFFERENCE, not the whole amount, so
    # [10, 100, 500] costs 500 inserts rather than 610.
    config.scale_factors = [10, 100, 500]

    # Batched, so a 500-row seed is a handful of inserts rather than 500.
    config.seed_batch_size = 50

    # Deletes only the rows Loadwright created, tracked by id. NEVER a TRUNCATE:
    # your development database holds seed data, fixtures, and hand-made state that
    # a blanket truncate would destroy.
    config.seed_cleanup_strategy = :delete_created_rows

    # Traffic realism. Every request authenticating as the same user produces
    # identical cache keys and identical tenant scoping, which can make a badly
    # scoped query look fine because there is only one tenant's data to filter.
    config.test_identity_pool_size = 5

    config.requests_per_endpoint_per_level = 25
  end
end

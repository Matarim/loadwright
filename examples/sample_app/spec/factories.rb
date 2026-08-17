# frozen_string_literal: true

# FactoryBot factories for the fixture app.
#
# Note the `tag` factory. It has NO sequence on `name`, which has a unique index —
# so seeding more than one tag raises, deliberately. That is the collision path
# SKILL.md is explicit about: Loadwright must report exactly which factory and field
# collided with a suggested `sequence(...)` fix, and skip that resource, rather than
# silently generating a unique value behind the user's back. Working around a missing
# sequence produces data that does not match how the app is actually used, so the
# collision has to be surfaced — and a fixture that never collides cannot prove it is.
#
# Do not add a sequence to :tag. Use :unique_tag when you want tags that seed.

FactoryBot.define do
  factory :author do
    sequence(:name) { |n| "Author #{n}" }
    sequence(:slug) { |n| "author-#{n}" }
    sequence(:email) { |n| "author#{n}@example.com" }
  end

  factory :post do
    author
    sequence(:title) { |n| "Post #{n}" }
    body { "Body text for the post, long enough to have some size to it." }
    published { true }

    trait :draft do
      published { false }
    end

    # For the seeded-data-but-empty-response case: seeding these and hitting
    # posts#index (which scopes to published) returns [], which must be
    # `inconclusive` for "seeded records did not match the endpoint's scope" and
    # never a fast healthy endpoint.
    trait :with_comments do
      after(:create) do |post|
        FactoryBot.create_list(:comment, 3, post: post)
      end
    end
  end

  factory :comment do
    post
    sequence(:author_name) { |n| "Commenter #{n}" }
    body { "A comment." }
  end

  # DELIBERATELY MISSING a sequence. See the note above.
  factory :tag do
    name { "duplicate" }
  end

  factory :unique_tag, class: "Tag" do
    sequence(:name) { |n| "tag-#{n}" }

    # Needed for the over-fetch fixture to bite. tags#index eager-loads
    # `posts: :comments`; with no join rows the comments query never runs at all,
    # so there is nothing loaded-but-unserialised to detect.
    trait :on_existing_posts do
      after(:create) do |tag|
        Post.order(:id).limit(3).each { |post| PostTag.create!(post: post, tag: tag) }
      end
    end
  end
end

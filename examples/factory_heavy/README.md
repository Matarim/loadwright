# Factory-heavy

A real `factory_map`, with traits and associations — and the uniqueness
collision you will hit on your first run.

## Who this is for

Anyone who wants the scale sweep to mean anything.

Without seeded data there is no slope, and without a slope the two most
valuable findings are reported as *not checked* rather than as clean:

- **query count grows with records returned** — the N+1 signature
- **payload grows with table size** — the missing-pagination signature

## The collision you will hit

FactoryBot factories written for unit tests usually create one record at a
time, so a hardcoded attribute never collides:

```ruby
factory :author do
  email { "author@example.com" }   # fine for one record
end
```

Loadwright creates two hundred. The unique index fires on the second, and you
get:

```
Seeding collision on factory :author, field `email`.
Add a sequence:

  factory :author do
    sequence(:email) { |n| "author#{n}@example.com" }
  end
```

**Loadwright will not work around this for you.** It could generate a unique
value and carry on. It deliberately does not, for two reasons: the data would
no longer match how your app is actually used, and the workaround would hide
a real gap in your factories behind a tool-specific patch. Fixing the factory
fixes it for your whole suite.

## Traits are where the N+1 comes from

```ruby
"post" => { factory: :post, trait: :with_comments }
```

A post with no comments cannot demonstrate a per-comment query. If your N+1
lives in a `has_many`, the trait that creates the children is the thing that
makes it visible — without it the endpoint looks clean at every scale.

## Cleanup

`:delete_created_rows` deletes only the rows Loadwright created, tracked by
id. It is never a `TRUNCATE`.

That matters more than it sounds: your development database holds seed data,
fixtures, and hand-made state you may have spent real time on. A tool that
truncates to clean up after itself has destroyed all of it, and the fact that
it was "only development" is no comfort at all.

If a batch fails partway, the rows it already committed are adopted into the
cleanup set rather than orphaned.

## Identity rotation

`test_identity_pool_size` seeds several users and rotates across them. Every
request authenticating as the same user produces identical cache keys and
identical tenant scoping — which can make a badly scoped query look perfectly
fine, because there is only one tenant's data to filter.

# frozen_string_literal: true

require "graphql"

# FIXTURE. A real graphql-ruby schema, so per-resolver attribution is proven against
# the tracing API it actually integrates with rather than against a stand-in.
#
# The flaws are load bearing: AuthorType#postCount issues one COUNT per author, so a
# paginated query's cost tracks `first:` and not the table size.
module SampleGraphql
  class AuthorType < GraphQL::Schema::Object
    field :id, ID, null: false
    field :name, String, null: false
    field :post_count, Integer, null: false

    # The N+1.
    def post_count = object.posts.count
  end

  class PostType < GraphQL::Schema::Object
    field :id, ID, null: false
    field :title, String, null: false
    field :comment_count, Integer, null: false

    # A second N+1, in a different resolver, so attribution has to tell them apart.
    def comment_count = object.comments.count
  end

  class QueryType < GraphQL::Schema::Object
    field :authors, [AuthorType], null: false do
      argument :first, Integer, required: false, default_value: 25
    end

    field :posts, [PostType], null: false do
      argument :first, Integer, required: false, default_value: 25
    end

    def authors(first:) = Author.order(:id).limit(first)

    def posts(first:) = Post.published.order(:id).limit(first)
  end

  class Schema < GraphQL::Schema
    query QueryType
    trace_with Loadwright::Instrumentation::GraphqlTracer
  end
end

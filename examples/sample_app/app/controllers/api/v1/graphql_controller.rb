# frozen_string_literal: true

module Api
  module V1
    # FIXTURE. A deliberately tiny GraphQL-shaped endpoint.
    #
    # NOT graphql-ruby: taking a dependency on it to prove Loadwright can drive a
    # GraphQL endpoint would be testing someone else's gem. What matters here is the
    # protocol shape Loadwright has to cope with, and all of it is here:
    #
    #   * every operation is a POST to one path, so the operation name is the identity
    #   * a failed query answers HTTP 200 with an `errors` array and no data, which is
    #     the thing that makes an unaware tool report a total failure as healthy
    #   * a resolver N+1 looks exactly like a REST one from the database's side
    #
    # `posts` has the same per-post COUNT the REST fixture has, so a GraphQL run
    # should find the same N+1 with the same suggestion.
    class GraphqlController < ActionController::API
      def create
        operation = params[:operationName].to_s
        case operation
        when "PostsWithCommentCounts" then render json: { data: { posts: posts_payload } }
        when "AuthorCount" then render json: { data: { authorCount: Author.count } }
        when "PagedAuthors" then render json: { data: { authors: paged_authors_payload } }
        else
          # The GraphQL failure shape: 200, no data, errors present.
          render json: { errors: [{ message: "No operation named #{operation.inspect}" }] }
        end
      end

      private

      # PAGINATED, with the same per-author N+1 authors#index has. Query count is flat
      # against seeded scale and only moves with `first:` -- the blind spot the
      # page-size sweep exists for, in GraphQL's own shape.
      def paged_authors_payload
        first = params.dig(:variables, :first) || 25
        nodes = Author.order(:id).limit(first.to_i).map do |author|
          { id: author.id, name: author.name, postCount: author.posts.count }
        end
        { nodes: nodes }
      end

      def posts_payload
        Post.published.order(:id).map do |post|
          # The N+1, matching posts#index.
          { id: post.id, title: post.title, commentCount: post.comments.count }
        end
      end
    end
  end
end

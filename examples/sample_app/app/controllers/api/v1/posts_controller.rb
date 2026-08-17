# frozen_string_literal: true

module Api
  module V1
    # FIXTURE. The flaws here are load bearing — do not fix them.
    class PostsController < ActionController::API
      # UNPAGINATED, and N+1 on comments.
      #
      # Two findings in one endpoint, deliberately, because they are independent and
      # a report must not collapse them:
      #
      #   * payload grows linearly with seeded rows -> missing pagination. No
      #     query-count signal will ever surface this: loading 10,000 rows can be a
      #     single efficient query.
      #   * one COUNT per post -> N+1. Visible to the seeded-scale slope precisely
      #     BECAUSE the endpoint is unpaginated, which is what makes authors#index
      #     the interesting contrast.
      def index
        posts = Post.published.order(:id)

        render json: posts.map { |post|
          {
            id: post.id,
            title: post.title,
            # The N+1.
            comment_count: post.comments.count
          }
        }
      end

      def show
        post = Post.find_by(id: params[:id])
        return render json: { error: "not found" }, status: :not_found unless post

        render json: { id: post.id, title: post.title, body: post.body, author_id: post.author_id }
      end

      def create
        post = Post.new(
          title: params[:title],
          body: params[:body],
          author_id: params[:author_id] || Author.order(:id).first&.id
        )

        if post.save
          render json: { id: post.id, title: post.title }, status: :created
        else
          render json: { errors: post.errors.full_messages }, status: :unprocessable_entity
        end
      end
    end
  end
end

# frozen_string_literal: true

module Api
  module V1
    # The CLEAN endpoint. A run that finds problems everywhere is as untrustworthy
    # as one that finds them nowhere, so the fixture needs at least one endpoint
    # that is genuinely correct: nested, paginated, indexed, and properly preloaded.
    class CommentsController < ActionController::API
      def index
        post = Post.find_by(id: params[:post_id])
        return render json: { error: "not found" }, status: :not_found unless post

        comments = post.comments.order(:id).limit(50)

        render json: comments.map { |comment|
          { id: comment.id, author_name: comment.author_name, body: comment.body }
        }
      end
    end
  end
end

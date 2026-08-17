# frozen_string_literal: true

module Api
  module V1
    # FIXTURE. The flaws here are load bearing — do not fix them.
    class TagsController < ActionController::API
      # OVER-FETCHING. Eager-loads posts and their comments, then serialises neither.
      #
      # Note what makes this a HINT rather than a finding: `posts.any?` is a real
      # use of the loaded data, and plenty of legitimate code loads records for
      # authorization or filtering without serialising them. A tool that reported
      # this as a defect would be crying wolf about ordinary authorization queries,
      # which is how a tool gets uninstalled.
      def index
        tags = Tag.includes(posts: :comments).order(:id).limit(25)

        render json: tags.map { |tag|
          { id: tag.id, name: tag.name, in_use: tag.posts.any? }
        }
      end
    end
  end
end

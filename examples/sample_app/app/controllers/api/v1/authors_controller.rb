# frozen_string_literal: true

module Api
  module V1
    # FIXTURE. The flaws here are load bearing — do not fix them.
    class AuthorsController < ActionController::API
      DEFAULT_PER_PAGE = 25
      MAX_PER_PAGE = 200

      # THE REGRESSION FIXTURE for response-analysis.md Part 2, and the reason that
      # subsystem exists.
      #
      # This endpoint is correctly paginated AND has a severe N+1. Because it
      # paginates, it returns the same 25 records whether the table holds 10 rows or
      # 10,000 — so its query count is FLAT against seeded scale, and a
      # seeded-scale slope reports it as perfectly healthy.
      #
      # The N+1 is only visible when the number of RETURNED records varies, which is
      # what sweeping per_page does. That is the blind spot, in a live fixture rather
      # than a mock.
      def index
        authors = Author.order(:id).limit(per_page).offset(offset)

        render json: authors.map { |author|
          {
            id: author.id,
            name: author.name,
            # The N+1 — one COUNT per returned author, so query count tracks
            # per_page and not the table size.
            post_count: author.posts.count
          }
        }
      end

      def show
        author = Author.find_by(id: params[:id])
        return render json: { error: "not found" }, status: :not_found unless author

        render json: { id: author.id, name: author.name, slug: author.slug }
      end

      # Exists so path-param resolution has a non-numeric, non-inferrable segment to
      # deal with — the case config.path_param_overrides is for.
      def by_slug
        author = Author.find_by(slug: params[:slug])
        return render json: { error: "not found" }, status: :not_found unless author

        render json: { id: author.id, name: author.name, slug: author.slug }
      end

      private

      def per_page
        requested = params[:per_page].presence || params[:limit].presence || DEFAULT_PER_PAGE
        [[Integer(requested, exception: false) || DEFAULT_PER_PAGE, 1].max, MAX_PER_PAGE].min
      end

      def offset
        page = [Integer(params[:page].to_s, exception: false) || 1, 1].max
        (page - 1) * per_page
      end
    end
  end
end

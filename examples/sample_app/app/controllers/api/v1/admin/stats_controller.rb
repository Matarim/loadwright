# frozen_string_literal: true

module Api
  module V1
    module Admin
      # THE 403. The single most important fixture in this app.
      #
      # To a purely query-counting tool this is the healthiest endpoint in the API:
      # it returns in a couple of milliseconds having issued zero queries, so it
      # ranks at the top of any "clean" list. The response validity gate exists so
      # that ranking never happens — this must come out `inconclusive`, never
      # `healthy`.
      class StatsController < ActionController::API
        def show
          render json: { error: "forbidden" }, status: :forbidden
        end
      end
    end
  end
end

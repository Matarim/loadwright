# frozen_string_literal: true

module Api
  module V1
    # FIXTURE. Executes against the real graphql-ruby schema.
    class GqlController < ActionController::API
      def create
        result = SampleGraphql::Schema.execute(
          params[:query],
          variables: params[:variables] || {},
          operation_name: params[:operationName]
        )
        render json: result.to_h
      end
    end
  end
end

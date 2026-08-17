# frozen_string_literal: true

module Api
  module V1
    # FIXTURE. The one endpoint here that actually checks a credential.
    #
    # It exists because there was no live fixture for authentication at all, and that
    # is precisely how IdentityPool#resolve! came to be called from nowhere in lib/:
    # every request went out unauthenticated, every endpoint 401'd, and no test
    # noticed because no fixture endpoint cared whether a token was sent.
    #
    # Deliberately trivial. It is here to prove the header arrives, not to model
    # anyone's real authentication.
    class MeController < ActionController::API
      VALID_TOKENS = %w[token-alice token-bob token-carol].freeze

      def show
        token = request.headers["Authorization"].to_s.sub(/\ABearer\s+/, "")
        return render json: { error: "unauthorized" }, status: :unauthorized unless
          VALID_TOKENS.include?(token)

        render json: { token: token, authenticated: true }
      end
    end
  end
end

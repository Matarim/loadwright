# frozen_string_literal: true

module Api
  module V1
    # FIXTURE. A login endpoint, so config.auth_login has something real to log in to.
    #
    # Mirrors the shape of a normal token login without any of the security: post a
    # credential, get a token back in JSON, and a Set-Cookie for the session-auth
    # case. The passwords are in the source because this is a fixture and there is
    # nothing here worth protecting.
    class SessionsController < ActionController::API
      CREDENTIALS = {
        "alice@example.com" => "token-alice",
        "bob@example.com" => "token-bob",
        "carol@example.com" => "token-carol"
      }.freeze

      PASSWORD = "password"

      def create
        token = CREDENTIALS[params[:email].to_s] if params[:password].to_s == PASSWORD
        return render json: { error: "invalid credentials" }, status: :unauthorized if token.nil?

        response.set_header("Set-Cookie", "session=#{token}; path=/")
        render json: { token: token, user: { email: params[:email] } }, status: :created
      end
    end
  end
end

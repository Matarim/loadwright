# frozen_string_literal: true

require "json"

module Loadwright
  module Seeding
    # Logs in the way a client does, and keeps the token.
    #
    # WHY THIS EXISTS. `auth_token_provider` asks the user to produce a valid
    # credential from inside their initializer. For a JWT app that is a line of code;
    # for a session app it means hand-assembling a cookie, and for anything with a
    # real login flow it means reimplementing that flow in config. Unset or wrong
    # auth is the most common first-run failure this tool has, and "write the code
    # that mints a token" is a large part of why.
    #
    # So: name the request your own clients make, and where the token is in the
    # answer. Loadwright issues it through the same transport as the run.
    #
    # ONE LOGIN PER CREDENTIAL, ONCE, BEFORE THE RUN. Not per request -- a login is
    # usually the most expensive endpoint an app has (bcrypt is deliberately slow),
    # and paying it per request would put someone else's password hashing inside
    # every latency number this tool reports.
    #
    # These requests are NOT measured and NOT reported as endpoints. They are setup,
    # the same as seeding, and folding them into the results would report the login
    # endpoint's performance as though the run had been asked about it.
    class LoginFlow
      REQUIRED_KEYS = %i[path credentials extract].freeze

      def initialize(config: Loadwright.configuration, transport:, stdout: $stdout)
        @config = config
        @transport = transport
        @stdout = stdout
        @warnings = []
      end

      attr_reader :warnings

      def self.configured?(config) = !config.auth_login.nil?

      # Returns the tokens, in credential order.
      def tokens
        spec = validated_spec
        credentials = Array(spec[:credentials])

        @stdout.puts "loadwright: logging in #{credentials.length} identity(s) via " \
                     "#{spec[:verb].to_s.upcase} #{spec[:path]}"

        credentials.map { |credential| token_for(spec, credential) }
      end

      private

      # Fails here rather than at the first request, so a typo in the initializer is a
      # configuration error with a name, not a mysterious 404 during setup.
      def validated_spec
        spec = symbolize(@config.auth_login)
        missing = REQUIRED_KEYS.reject { |key| spec[key] }
        unless missing.empty?
          raise ConfigurationError,
                "config.auth_login is missing #{missing.join(', ')}. It needs a path, a " \
                "credentials list, and an extract rule naming where the token is in the " \
                "response — for example:\n" \
                "  config.auth_login = {\n" \
                "    path: \"/api/v1/login\",\n" \
                "    credentials: [{ email: \"dev@example.com\", password: \"password\" }],\n" \
                "    extract: { json: \"token\" }\n" \
                "  }"
        end

        spec[:verb] ||= :post
        spec
      end

      def token_for(spec, credential)
        response = @transport.issue(
          Execution::Request.new(
            verb: spec[:verb],
            path: spec[:path],
            # No Content-Type of our own. Each transport already encodes a body the way
            # its medium needs -- :http serialises to JSON and says so, :in_process
            # hands the hash to ActionDispatch as params -- and forcing one here told
            # ActionDispatch to parse form-encoded data as JSON, which answered 400.
            headers: spec[:headers] || {},
            body: credential,
            endpoint_key: "LOGIN #{spec[:path]}"
          )
        )

        raise SeedingError, failure_message(spec, response) unless success?(response)

        extract(spec[:extract], response) ||
          raise(SeedingError, extraction_message(spec, response))
      end

      def success?(response) = response.status.to_i.between?(200, 299)

      def extract(rule, response)
        rule = symbolize(rule)

        return header_value(response, rule[:header]) if rule[:header]
        return json_value(response, rule[:json]) if rule[:json]

        raise ConfigurationError,
              "config.auth_login[:extract] must name either :json (a dot path into the " \
              "response body) or :header (a response header name)"
      end

      # Case-insensitively, because header casing is not something a user should have
      # to guess and Rack, Net::HTTP and ActionDispatch do not agree on it.
      def header_value(response, name)
        wanted = name.to_s.downcase
        _, value = response.headers.to_h.find { |key, _| key.to_s.downcase == wanted }
        value.is_a?(Array) ? value.first : value
      end

      def json_value(response, path)
        parsed = JSON.parse(response.body.to_s)
        path.to_s.split(".").reduce(parsed) do |node, key|
          break nil unless node.is_a?(Hash)

          node[key]
        end
      rescue JSON::ParserError
        nil
      end

      def symbolize(hash)
        (hash || {}).to_h { |key, value| [key.to_s.to_sym, value] }
      end

      # NEVER the response body: a failed login answer can echo the credential back,
      # and this message goes to a terminal and into a report.
      def failure_message(spec, response)
        "config.auth_login could not log in: #{spec[:verb].to_s.upcase} #{spec[:path]} " \
          "answered #{response.status}. Every request in the run would be unauthenticated. " \
          "Check the path, the credential, and that the user exists in this environment. " \
          "(The response body is not shown here because a login response can echo the " \
          "credential back.)"
      end

      def extraction_message(spec, response)
        "config.auth_login logged in successfully (#{response.status}) but no token was found " \
          "where #{symbolize(spec[:extract]).inspect} said it would be. Check the shape of your " \
          "login response."
      end
    end
  end
end

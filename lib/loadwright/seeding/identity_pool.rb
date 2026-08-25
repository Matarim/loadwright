# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Seeding
    # Rotates auth identities across requests.
    #
    # WHY THIS IS NOT OPTIONAL POLISH. Single-identity traffic lies, in three
    # specific ways that all make a bad endpoint look fine:
    #
    #   * Identical cache keys — one user's requests hit a warm cache the second
    #     time, so measured latency is a cache-hit measurement.
    #   * Single-tenant scoping — a query that is badly scoped across tenants looks
    #     correctly scoped when every request is the same tenant.
    #   * Row-lock contention on one user's rows, which is contention no real
    #     traffic pattern would produce.
    #
    # So `auth_token_provider` returning ONE token is a documented warning, not a
    # convenience. AGENTS.md says the same under the JWT cookbook entry.
    class IdentityPool
      Identity = Struct.new(:token, :index, keyword_init: true)

      attr_reader :warnings

      def initialize(config: Loadwright.configuration, stdout: $stdout)
        @config = config
        @stdout = stdout
        @warnings = []
        @cursor = 0
        @mutex = Mutex.new
      end

      # Resolves the provider once, at run start. Calling it per request would make
      # token issuance part of every measurement — and for a JWT issuer doing bcrypt
      # work, a large part.
      # `transport` is only needed for config.auth_login, which issues a real login
      # request. A token provider needs nothing, and a public API needs neither.
      def resolve!(transport: nil)
        # Idempotent: the runner resolves at run start, and a caller that resolved
        # first must not cause the provider -- which may be issuing JWTs or hitting a
        # login endpoint -- to run twice.
        return self if @tokens

        tokens = resolve_tokens(transport)
        return self if tokens.nil?

        if tokens.empty?
          raise SeedingError,
                "config.auth_token_provider returned no usable token. Every request would be " \
                "unauthenticated, and the run would report every endpoint inconclusive for a 401 " \
                "or 403 — which says nothing about your endpoints. Verify it with:\n" \
                "  rails runner 'puts Loadwright.config.auth_token_provider.call.inspect'"
        end

        if tokens.length == 1
          @warnings << "auth_token_provider returned a single token, so all traffic is one identity: " \
                       "identical cache keys, single-tenant scoping, and row-lock contention on one " \
                       "user's rows. A badly-scoped query can look correctly scoped this way. Return a " \
                       "collection of tokens (see test_identity_pool_size)."
        end

        @tokens = tokens.freeze
        self
      end

      private

      # nil means "no authentication was configured", which is different from "it was
      # configured and produced nothing" -- the second raises below.
      def resolve_tokens(transport)
        if LoginFlow.configured?(@config)
          return login_tokens(transport)
        end

        provider = @config.auth_token_provider
        return nil if provider.nil?

        Array(call_provider(provider)).compact.map(&:to_s).reject(&:empty?)
      end

      def login_tokens(transport)
        if transport.nil?
          raise ConfigurationError,
                "config.auth_login needs a transport to issue its login request, and none was " \
                "available. This is a wiring problem inside Loadwright, not your configuration."
        end

        flow = LoginFlow.new(config: @config, transport: transport, stdout: @stdout)
        tokens = Array(flow.tokens).compact.map(&:to_s).reject(&:empty?)
        @warnings.concat(flow.warnings)
        tokens
      end

      public


      def resolved? = !@tokens.nil?

      def size = @tokens&.length || 0

      # Round-robin rather than random: a run must be reproducible, and a random
      # identity per request makes two runs incomparable for no benefit.
      def next_identity
        return nil unless resolved?

        @mutex.synchronize do
          identity = Identity.new(token: @tokens[@cursor % @tokens.length], index: @cursor)
          @cursor += 1
          identity
        end
      end

      # The headers a request should carry for the next identity. Empty when no
      # provider is configured, which is correct for a genuinely public API.
      def headers_for_next
        identity = next_identity
        return {} if identity.nil?

        case @config.auth_strategy
        when :bearer_token then { "Authorization" => "Bearer #{identity.token}" }
        when :session then { "Cookie" => identity.token }
        when :header then { "X-Api-Key" => identity.token }
        else
          raise ConfigurationError,
                "unknown auth_strategy #{@config.auth_strategy.inspect}; " \
                "expected one of #{Configuration::AUTH_STRATEGIES.join(', ')}"
        end
      end

      def to_h
        {
          strategy: @config.auth_strategy,
          identities: size,
          configured: !@config.auth_token_provider.nil?,
          warnings: @warnings
        }
      end

      private

      def call_provider(provider)
        return provider.call if provider.respond_to?(:call)

        provider
      rescue StandardError => e
        raise SeedingError,
              "config.auth_token_provider raised #{e.class}: #{e.message}. Without a token every " \
              "request is unauthenticated and the whole run reports inconclusive, so this aborts " \
              "rather than producing a report full of 401s."
      end
    end
  end
end

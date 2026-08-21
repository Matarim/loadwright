# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Analysis
    # The two things that go wrong on a first run, diagnosed in plain language.
    #
    # ===========================================================================
    # WHY THIS EXISTS AT ALL. The response validity gate is correct to mark a 429 or a
    # 403 `inconclusive` — no performance verdict may be attached to a response that
    # did not prove it did the work. But correct is not the same as useful. A first-time
    # user whose `auth_token_provider` is not wired up gets a report in which every
    # single endpoint is `inconclusive`, each with an accurate per-endpoint reason and
    # no explanation of the one thing that caused all of them.
    #
    # The pattern is only visible ACROSS endpoints, which is why this is a run-level
    # diagnosis rather than a per-endpoint one. A single 403 means an admin endpoint.
    # Every endpoint returning 403 means the token is wrong, and saying so turns a
    # baffling report into a one-line fix.
    # ===========================================================================
    #
    # It also RE-LABELS the affected endpoints. EndpointOutcome already enumerates
    # `:auth_failed` and `:rate_limited` for exactly this, and their explanations name
    # the fix — where `:unsuccessful_status` only says an error path was measured.
    class TrafficDiagnosis
      # Rate limiting announces itself in headers as well as in the status. Any of these
      # present on a response is strong evidence even without a 429, because a limiter
      # in "log only" mode still sets them.
      RATE_LIMIT_HEADERS = %w[
        retry-after
        ratelimit-limit ratelimit-remaining ratelimit-reset
        x-ratelimit-limit x-ratelimit-remaining x-ratelimit-reset
      ].freeze

      AUTH_STATUSES = [401, 403].freeze

      # ONE 429 IS ENOUGH TO NAME THE CAUSE for the endpoint that got it -- a 429 is
      # unambiguous, unlike a 403. This fraction governs the RUN-LEVEL advice, which is
      # a different claim: "rate limiting is shaping this whole run, allowlist us".
      RATE_LIMITED_RUN_FRACTION = 0.25

      # Deliberately high, and not a config key. The claim being made is "your token
      # provider is misconfigured", which is wrong and confusing for an app that
      # genuinely has a mostly-admin API. At 80% the alternative explanation -- that
      # four fifths of the API is legitimately forbidden to this identity -- is far
      # less likely than the token being wrong, and the diagnosis is advisory text
      # plus a more useful `inconclusive` reason rather than a verdict on the app.
      AUTH_FAILURE_RUN_FRACTION = 0.8

      # Below this there is no "across endpoints" to reason about, and one or two
      # forbidden endpoints in a two-endpoint run is just an API with an admin section.
      MIN_ENDPOINTS_FOR_UNIFORMITY = 3

      Diagnosis = Struct.new(:kind, :message, :affected_endpoints, :evidence, keyword_init: true) do
        def to_h = { kind: kind, message: message, affected_endpoints: affected_endpoints,
                     evidence: evidence }
      end

      def initialize(config: Loadwright.configuration)
        @config = config
      end

      # `observations` maps an endpoint key to { statuses: [...], rate_limit_headers: {...} }.
      def diagnose(observations)
        observations = observations.reject { |_, o| Array(o[:statuses]).empty? }

        [rate_limiting(observations), auth_misconfiguration(observations)].compact
      end

      # Per-endpoint reason override, applied by the engine before the outcome is
      # derived. Returns nil when nothing more specific than the validity gate's own
      # reason can be said.
      def reason_for(endpoint_key, observation, diagnoses)
        statuses = Array(observation[:statuses])
        return nil if statuses.empty?

        # A 429 names itself. No run-level agreement needed.
        return :rate_limited if statuses.include?(429) || rate_limit_headers?(observation)

        kinds = diagnoses.map(&:kind)
        if kinds.include?(:auth_misconfigured) &&
           statuses.any? { |status| AUTH_STATUSES.include?(status) }
          return :auth_failed
        end

        nil
      end

      private

      def rate_limiting(observations)
        limited = observations.select do |_, observation|
          Array(observation[:statuses]).include?(429) || rate_limit_headers?(observation)
        end
        return nil if limited.empty?

        fraction = limited.length.to_f / observations.length
        return nil if fraction < RATE_LIMITED_RUN_FRACTION

        headers = limited.values.flat_map { |o| (o[:rate_limit_headers] || {}).keys }.uniq

        Diagnosis.new(
          kind: :rate_limited,
          message: "Rate limiting is throttling this run: #{limited.length} of #{observations.length} " \
                   "endpoint(s) were limited#{headers.empty? ? '' : " (#{headers.join(', ')})"}. " \
                   "The measurements below reflect the limiter, not the app. Allowlist Loadwright's " \
                   "requests, or disable rate limiting for this environment, and run again.",
          affected_endpoints: limited.keys,
          evidence: { limited_endpoints: limited.length, total_endpoints: observations.length,
                      headers_seen: headers }
        )
      end

      def auth_misconfiguration(observations)
        return nil if observations.length < MIN_ENDPOINTS_FOR_UNIFORMITY

        failing = observations.select do |_, observation|
          statuses = Array(observation[:statuses])
          statuses.any? && statuses.all? { |status| AUTH_STATUSES.include?(status) }
        end
        return nil if failing.empty?

        fraction = failing.length.to_f / observations.length
        return nil if fraction < AUTH_FAILURE_RUN_FRACTION

        Diagnosis.new(
          kind: :auth_misconfigured,
          message: "#{failing.length} of #{observations.length} endpoint(s) returned only 401/403. " \
                   "Across an API this is almost always #{provider_hint} rather than an API where " \
                   "everything is forbidden. Nothing below is a measurement of the app; fix the " \
                   "credentials and run again.",
          affected_endpoints: failing.keys,
          evidence: { failing_endpoints: failing.length, total_endpoints: observations.length,
                      auth_strategy: @config.auth_strategy,
                      auth_token_provider_configured: !@config.auth_token_provider.nil? }
        )
      end

      # The most likely cause first, and it differs depending on whether the user has
      # configured anything at all -- "your provider is wrong" is unhelpful advice to
      # someone who has not set one.
      def provider_hint
        return "auth_token_provider not being configured at all" if @config.auth_token_provider.nil?

        "auth_token_provider returning a token the app rejects (expired, wrong scope, or for a " \
          "user that does not exist in the seeded data)"
      end

      def rate_limit_headers?(observation)
        (observation[:rate_limit_headers] || {}).any?
      end
    end
  end
end

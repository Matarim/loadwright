# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  # The verdict attached to one endpoint after a run.
  #
  # Three states, never two (CLAUDE.md corollary 5):
  #
  #   :healthy      — measured successfully, nothing notable found
  #   :has_findings — measured successfully, problems found
  #   :inconclusive — could not be measured validly or safely
  #
  # :inconclusive is the state that makes the other two trustworthy. Without it,
  # an endpoint returning 403 in 4ms with one query ranks as the healthiest in
  # the API, and an endpoint returning [] because seeded records missed its
  # scope looks identical to a well-optimised one.
  #
  # Quarantine is modelled as a *reason* for :inconclusive rather than a fourth
  # state, which satisfies both CLAUDE.md ("three outcome states, never two")
  # and reporting.md section 4 (quarantined endpoints must render visually
  # distinct from externally-blocked ones). Callers ask #quarantined?.
  class EndpointOutcome
    STATES = %i[healthy has_findings inconclusive].freeze

    # Reasons an endpoint ends up :inconclusive. Each maps to a distinct action
    # for the reader, which is why they are enumerated rather than free text.
    REASONS = {
      # Response validity gate — see response-analysis.md Part 1.
      unsuccessful_status: "endpoint returned an error status; an error path was measured, not the endpoint",
      schema_invalid: "response did not validate against its declared OpenAPI schema",
      empty_with_seeded_data: "data was seeded but the endpoint returned an empty collection; " \
                              "seeded records likely do not match the endpoint's scope",
      inconsistent_shape: "response structure changed across scale factors; cross-scale comparison is invalid",

      # Setup problems that prevent a request being issued at all.
      path_params_unresolved: "path parameters could not be resolved to real records",
      no_example_available: "endpoint discovered but no usable example request was available",
      auth_failed: "authentication failed uniformly; auth_token_provider is likely misconfigured",
      rate_limited: "requests were throttled; allowlist Loadwright or disable rate limiting for this environment",

      # Contention — see resource-contention.md.
      quarantined: "our own load caused sustained contention; endpoint abandoned after the backoff ladder",
      externally_blocked: "contention was caused by a session that is not ours; not attributable to this endpoint",

      # Run-level aborts.
      circuit_breaker: "skipped; the circuit breaker aborted the run before this endpoint was reached",
      run_aborted: "skipped; the run was aborted before this endpoint was reached",
      interrupted: "skipped; the run was interrupted"
    }.freeze

    # Reasons that mean "we could not measure this", as distinct from "we did
    # not get to it". Both are :inconclusive, but only the first says anything
    # about the endpoint.
    QUARANTINE_REASONS = %i[quarantined].freeze
    EXTERNAL_REASONS   = %i[externally_blocked].freeze
    SKIPPED_REASONS    = %i[circuit_breaker run_aborted interrupted].freeze

    class << self
      def healthy(endpoint:, capability_epoch: 0)
        new(endpoint: endpoint, state: :healthy, capability_epoch: capability_epoch)
      end

      def has_findings(endpoint:, findings:, capability_epoch: 0)
        raise ArgumentError, ":has_findings requires at least one finding" if Array(findings).empty?

        new(endpoint: endpoint, state: :has_findings, findings: findings, capability_epoch: capability_epoch)
      end

      def inconclusive(endpoint:, reason:, detail: nil, capability_epoch: 0)
        raise ArgumentError, "unknown inconclusive reason #{reason.inspect}" unless REASONS.key?(reason)

        new(
          endpoint: endpoint, state: :inconclusive, reason: reason,
          detail: detail, capability_epoch: capability_epoch
        )
      end
    end

    attr_reader :endpoint, :state, :reason, :detail, :findings, :capability_epoch

    def initialize(endpoint:, state:, reason: nil, detail: nil, findings: [], capability_epoch: 0)
      raise ArgumentError, "unknown state #{state.inspect}" unless STATES.include?(state)

      @endpoint = endpoint
      @state = state
      @reason = reason
      @detail = detail
      @findings = Array(findings).freeze
      @capability_epoch = capability_epoch
      freeze
    end

    def healthy?      = state == :healthy
    def has_findings? = state == :has_findings
    def inconclusive? = state == :inconclusive

    def quarantined?       = inconclusive? && QUARANTINE_REASONS.include?(reason)
    def externally_blocked? = inconclusive? && EXTERNAL_REASONS.include?(reason)
    def skipped?           = inconclusive? && SKIPPED_REASONS.include?(reason)

    # Only endpoints we actually measured and found clean belong in the clean
    # list, the summary rankings, or a pass/fail exit code. response-analysis.md
    # Part 1 requires inconclusive endpoints be excluded from all three.
    def countable_as_clean? = healthy?

    def explanation
      return nil unless inconclusive?

      base = REASONS.fetch(reason)
      detail ? "#{base} (#{detail})" : base
    end

    def to_h
      {
        endpoint: endpoint,
        state: state,
        reason: reason,
        explanation: explanation,
        findings: findings,
        capability_epoch: capability_epoch
      }.compact
    end
  end
end

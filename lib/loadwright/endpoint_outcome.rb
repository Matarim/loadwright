# frozen_string_literal: true

require "loadwright/coverage"
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
      # GraphQL answers 200 for a query that failed completely, so status alone says
      # nothing about whether the endpoint did any work.
      graphql_errors: "the response carried GraphQL errors; the query failed and an error path was " \
                      "measured, whatever the HTTP status said",

      # Setup problems that prevent a request being issued at all.
      path_params_unresolved: "path parameters could not be resolved to real records",
      no_example_available: "endpoint discovered but no usable example request was available",
      auth_failed: "authentication failed uniformly; auth_token_provider is likely misconfigured",
      # SAME SENTENCE AS :unsuccessful_status, deliberately. Both mean every request
      # came back a non-success status; which mechanism noticed is not something a
      # reader should have to model. The symbol stays distinct for the machine-readable
      # output, where the difference is worth having.
      endpoint_erroring: "endpoint returned an error status; an error path was measured, not the " \
                         "endpoint. It failed on nearly every request, so it was quarantined and the " \
                         "rest of the run continued without it",
      rate_limited: "requests were throttled; allowlist Loadwright or disable rate limiting for this environment",

      # Coverage — see response-analysis.md. Distinct from the validity-gate reasons
      # above: the response was fine and the measurements we DID take were valid.
      # What is missing is a whole class of finding we could not look for at all, so
      # the endpoint cannot be called clean without overstating what was checked.
      incomplete_coverage: "one or more classes of finding could not be checked for this endpoint, " \
                           "so it cannot be reported as clean",

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
      def healthy(endpoint:, capability_epoch: 0, coverage: nil)
        new(endpoint: endpoint, state: :healthy, capability_epoch: capability_epoch, coverage: coverage)
      end

      def has_findings(endpoint:, findings:, capability_epoch: 0, coverage: nil)
        raise ArgumentError, ":has_findings requires at least one finding" if Array(findings).empty?

        new(endpoint: endpoint, state: :has_findings, findings: findings,
            capability_epoch: capability_epoch, coverage: coverage)
      end

      def inconclusive(endpoint:, reason:, detail: nil, capability_epoch: 0, coverage: nil)
        raise ArgumentError, "unknown inconclusive reason #{reason.inspect}" unless REASONS.key?(reason)

        new(
          endpoint: endpoint, state: :inconclusive, reason: reason,
          detail: detail, capability_epoch: capability_epoch, coverage: coverage
        )
      end

      # THE STATE DERIVATION. One place, so reporting renders a state rather than
      # recomputing one, and so the precedence is stated once instead of being
      # rediscovered per format.
      #
      #   1. findings                  -> :has_findings
      #   2. a finding class uncovered -> :inconclusive(:incomplete_coverage)
      #   3. otherwise                 -> :healthy
      #
      # Findings take precedence over a coverage gap deliberately: a concrete defect
      # is the most actionable thing we can say, and the gap stays visible anyway
      # because coverage is reported on every endpoint regardless of state.
      #
      # The validity gate runs BEFORE this — a response that did not prove it did the
      # work is inconclusive for that reason, and no coverage question arises.
      def derive(endpoint:, findings: [], coverage: Coverage.none, capability_epoch: 0)
        findings = Array(findings)

        return has_findings(endpoint: endpoint, findings: findings,
                            capability_epoch: capability_epoch, coverage: coverage) if findings.any?

        if coverage.uncovered_classes.any?
          return inconclusive(
            endpoint: endpoint, reason: :incomplete_coverage,
            detail: "could not check: #{coverage.uncovered_detail}",
            capability_epoch: capability_epoch, coverage: coverage
          )
        end

        healthy(endpoint: endpoint, capability_epoch: capability_epoch, coverage: coverage)
      end
    end

    attr_reader :endpoint, :state, :reason, :detail, :findings, :capability_epoch, :coverage

    def initialize(endpoint:, state:, reason: nil, detail: nil, findings: [], capability_epoch: 0,
                   coverage: nil)
      raise ArgumentError, "unknown state #{state.inspect}" unless STATES.include?(state)

      @endpoint = endpoint
      @state = state
      @reason = reason
      @detail = detail
      @findings = Array(findings).freeze
      @capability_epoch = capability_epoch
      @coverage = coverage || Coverage.none
      freeze
    end

    def healthy?      = state == :healthy
    def has_findings? = state == :has_findings
    def inconclusive? = state == :inconclusive

    # Distinguishes "we could not measure this endpoint" from "we measured it and one
    # class of check was missing". Both are inconclusive; only the second says the
    # endpoint itself was fine as far as we looked.
    def incomplete_coverage? = inconclusive? && reason == :incomplete_coverage

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
        capability_epoch: capability_epoch,
        coverage: coverage.to_h
      }.compact
    end
  end
end

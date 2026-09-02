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
      # DECLINED BY POLICY, NOT UNMEASURABLE. This used to share :no_example_available
      # with an endpoint that genuinely had nothing to send -- two situations with
      # different fixes, collapsed into one number. In one real run 45 of 73
      # inconclusive endpoints were this, so a reader trying to improve coverage could
      # not tell that most of the gap was one config switch away rather than a
      # measurement failure.
      mutating_not_allowed: "endpoint uses a mutating verb and allow_mutating_requests is false, so it " \
                            "was never requested. Not a measurement failure: nothing was attempted",
      auth_failed: "authentication failed uniformly; auth_token_provider is likely misconfigured",
      # SAME SENTENCE AS :unsuccessful_status, deliberately. Both mean every request
      # came back a non-success status; which mechanism noticed is not something a
      # reader should have to model. The symbol stays distinct for the machine-readable
      # output, where the difference is worth having.
      endpoint_erroring: "endpoint returned an error status; an error path was measured, not the " \
                         "endpoint. It failed on nearly every request, so it was quarantined and the " \
                         "rest of the run continued without it",
      rate_limited: "requests were throttled; allowlist Loadwright or disable rate limiting for this environment",
      # THE SWEEP CHOSE THE VALUE THAT FAILED. An endpoint answering 200 at its own
      # default and 400 at page sizes 5 and 100 is not broken -- it accepts a set of
      # page sizes and we asked for one outside it. Reporting that as an ordinary
      # error status points the reader at their app for something we did.
      page_size_rejected: "the endpoint rejected the page sizes the sweep asked for; it answered " \
                          "successfully at others, so this is the sweep's choice of value rather than " \
                          "the endpoint failing",

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

    # Reasons that mean "we chose not to look", as distinct from "we looked and could
    # not answer". Both are :inconclusive -- the three states are load-bearing and this
    # is not a fourth -- but they must be COUNTED separately, or a reader improving
    # coverage cannot tell which part of the number is theirs to move.
    DECLINED_REASONS   = %i[mutating_not_allowed].freeze

    class << self
      def healthy(endpoint:, capability_epoch: 0, coverage: nil)
        new(endpoint: endpoint, state: :healthy, capability_epoch: capability_epoch, coverage: coverage)
      end

      def has_findings(endpoint:, findings:, capability_epoch: 0, coverage: nil)
        raise ArgumentError, ":has_findings requires at least one finding" if Array(findings).empty?

        new(endpoint: endpoint, state: :has_findings, findings: findings,
            capability_epoch: capability_epoch, coverage: coverage)
      end

      # FINDINGS MEASURED ON A SUCCESSFUL RESPONSE SURVIVE A DISQUALIFICATION ON A
      # DIFFERENT AXIS.
      #
      # The validity gate exists because a performance verdict must never be attached to
      # a response that did not prove it did the work -- that is the round-5 healthy-404
      # lesson and it is not being loosened. But "the response did not prove it did the
      # work" and "the response did the work and does not match its documentation" are
      # different sentences, and only the first justifies throwing measurements away.
      #
      # An endpoint that answered 200 six hundred times, issued 73 queries per request,
      # and repeated one of them twelve times has a real N+1. A schema under-describing
      # its payload does not make that untrue. Discarding it there cost one integration
      # two consecutive rounds of a finding the tool had reported correctly in the eight
      # before -- silence being indistinguishable from health to anyone who was not
      # there for those rounds.
      #
      # The STATE is still `inconclusive`: three states are load-bearing, coverage
      # genuinely is incomplete, and `inconclusive` never fails the exit code (decision
      # 27). What changes is that the findings are carried and rendered rather than
      # dropped on the floor.
      def inconclusive(endpoint:, reason:, detail: nil, capability_epoch: 0, coverage: nil, findings: [])
        raise ArgumentError, "unknown inconclusive reason #{reason.inspect}" unless REASONS.key?(reason)

        new(
          endpoint: endpoint, state: :inconclusive, reason: reason, findings: findings,
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

    # Measured, real, and carrying no verdict -- the endpoint could not be judged, but
    # these were observed on responses that did the work. Reported under their own
    # heading so nobody reads them as a verdict, and never counted as `has_findings`.
    def retained_findings = inconclusive? ? findings : []

    def retained_findings? = retained_findings.any?

    def quarantined?       = inconclusive? && QUARANTINE_REASONS.include?(reason)
    def externally_blocked? = inconclusive? && EXTERNAL_REASONS.include?(reason)
    def skipped?           = inconclusive? && SKIPPED_REASONS.include?(reason)

    # Never attempted, by the user's own configuration. Reported, but not a gap this
    # run can be blamed for -- the endpoint-level twin of Coverage's :not_applicable.
    def declined?          = inconclusive? && DECLINED_REASONS.include?(reason)

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

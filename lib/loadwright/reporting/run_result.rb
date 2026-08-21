# frozen_string_literal: true

module Loadwright
  module Reporting
    # The one structure every report format renders from.
    #
    # This is the engine's output, not a rendering concern — the formats are views
    # over it. Building it as data first is deliberate: a shape that only exists
    # inside an HTML template cannot be diffed between runs, persisted, or checked,
    # and every one of those is a requirement elsewhere.
    #
    # NOTHING HERE MAY BRANCH ON config.execution_mode. The mode may be DISPLAYED in
    # run metadata — reporting.md requires it appear prominently so a reader never has
    # to guess which mode produced the numbers — and that read is marked
    # `capability-exempt`. Every decision about what is measurable consults
    # CapabilityProfile. A spec enforces this.
    #
    # THE THREE STATES ARE CARRIED THROUGH THE DATA MODEL, not assembled at render
    # time. #summary counts them separately, and `clean` deliberately means "healthy"
    # rather than "not has_findings" — "18 endpoints clean" is a lie if 12 of them
    # were inconclusive (AGENTS.md AP-02).
    class RunResult
      attr_reader :config, :started_at, :finished_at, :cells, :outcomes, :correlations,
                  :breaker, :guard, :seeder, :identities, :warnings, :aborted_reason,
                  :safety_decision, :containment, :discovery, :explain, :latency,
                  :time_breakdowns, :cold_warm, :pool_sizing, :traffic, :containment_disclosure

      def initialize(config:, cells:, outcomes:, context: nil, started_at: nil, finished_at: nil,
                     correlations: {}, breaker: nil, guard: nil, seeder: nil, identities: nil,
                     warnings: [], aborted_reason: nil, safety_decision: nil, containment: nil,
                     discovery: nil, explain: {}, latency: {}, time_breakdowns: {}, cold_warm: {},
                     pool_sizing: nil, traffic: nil, containment_disclosure: nil)
        @config = config
        @context = context
        @started_at = started_at
        @finished_at = finished_at
        @cells = cells
        @outcomes = outcomes
        @correlations = correlations
        @breaker = breaker
        @guard = guard
        @seeder = seeder
        @identities = identities
        @warnings = warnings
        @aborted_reason = aborted_reason
        @safety_decision = safety_decision
        @containment = containment
        @discovery = discovery
        @explain = explain
        @latency = latency
        @time_breakdowns = time_breakdowns
        @cold_warm = cold_warm
        @pool_sizing = pool_sizing
        @traffic = traffic
        @containment_disclosure = containment_disclosure
      end

      def duration_seconds
        return nil if started_at.nil? || finished_at.nil?

        finished_at - started_at
      end

      def healthy = outcomes.select(&:healthy?)
      def with_findings = outcomes.select(&:has_findings?)
      def inconclusive = outcomes.select(&:inconclusive?)

      # Deliberately not "outcomes minus those with findings". An inconclusive endpoint
      # is not a pass (INV-07).
      def clean = outcomes.select(&:countable_as_clean?)

      def quarantined = outcomes.select(&:quarantined?)
      def externally_blocked = outcomes.select(&:externally_blocked?)
      def skipped = outcomes.select(&:skipped?)

      def aborted? = !aborted_reason.nil?

      def summary
        {
          endpoints: outcomes.length,
          healthy: healthy.length,
          has_findings: with_findings.length,
          inconclusive: inconclusive.length,
          quarantined: quarantined.length,
          externally_blocked: externally_blocked.length,
          skipped: skipped.length,
          findings: with_findings.sum { |outcome| outcome.findings.length }
        }
      end

      # Ranked worst-first for the report's summary table, and drawn ONLY from endpoints
      # that were measured. An inconclusive endpoint has no position in a ranking:
      # including it would put a 403 at whichever end its 4ms latency landed.
      def ranked_findings
        with_findings.flat_map do |outcome|
          outcome.findings.map { |finding| { endpoint: outcome.endpoint.to_s, finding: finding } }
        end.sort_by { |entry| confidence_rank(entry[:finding]) }
      end

      def cells_for(endpoint_key) = cells.select { |cell| cell.endpoint_key == endpoint_key }

      # Everything production-safety.md requires be auditable from the report alone,
      # without the terminal scrollback.
      def metadata
        {
          loadwright_version: Loadwright::VERSION,
          started_at: started_at,
          finished_at: finished_at,
          duration_seconds: duration_seconds&.round(2),
          git_sha: git_sha,
          execution_mode: config.execution_mode, # capability-exempt: metadata display, per reporting.md
          transport: @context&.transport&.name,
          collector: @context&.collector&.collector_name,
          capabilities: @context&.to_h&.dig(:capabilities),
          sweeps: sweeps,
          config_fingerprint: config.comparability_fingerprint,
          config: config.snapshot,
          safety: safety_decision&.to_h,
          containment: containment&.to_h,
          # REQUIRED, not optional (performance-signals.md Part 1). A run with outbound
          # HTTP blocked is faster than reality, and the missing time appears in no
          # component at all -- so nothing in the numbers hints at it. It is repeated on
          # every endpoint's time breakdown too, because those get read separately.
          containment_disclosure: containment_disclosure&.to_h,
          discovery: discovery,
          seeding: seeder&.to_h,
          identities: identities&.to_h,
          circuit_breaker: breaker&.to_h,
          contention: guard&.to_h,
          pool_sizing: pool_sizing&.to_h,
          # The run-wide diagnoses that explain a report full of `inconclusive` -- rate
          # limiting, or an unwired auth_token_provider. In metadata rather than on an
          # endpoint because they are properties of the RUN, and a reader looking at
          # twelve inconclusive endpoints needs the one sentence that explains all of them.
          traffic: traffic_to_h,
          aborted: aborted?,
          aborted_reason: aborted_reason,
          warnings: warnings
        }.compact
      end

      def to_h
        {
          metadata: metadata,
          summary: summary,
          endpoints: outcomes.map { |outcome| endpoint_to_h(outcome) },
          cells: cells.map(&:to_h)
        }
      end

      # What each sweep held fixed, including the app's OWN default page size.
      #
      # The seed-scale sweep deliberately sends no page-size parameter, so the axis it
      # holds fixed is whatever the app defaults to — a property of the APP, not of the
      # run, and therefore invisible in the config fingerprint. Two runs against apps
      # with different defaults are not comparing the same thing, so the observed value
      # is recorded here for the comparability gate to check.
      #
      # Observed rather than configured, because Loadwright never told the app what page
      # size to use: it is read back from the record count at the largest seed scale,
      # where a paginated endpoint has filled its default page.
      def sweeps
        {
          seed_scale: {
            varies: :scale_factors,
            holds_fixed: "the app's own default page size (no page-size parameter is sent)",
            observed_page_size: observed_default_page_size,
            scale_factors: config.scale_factors
          },
          page_size: {
            varies: :page_size_sweep,
            holds_fixed: "seed scale, and concurrency at 1",
            page_size_sweep: config.page_size_sweep,
            concurrency: 1
          }
        }
      end

      # Per endpoint, so an app with different defaults per collection is visible rather
      # than averaged into one misleading number.
      def observed_default_page_size
        largest = config.scale_factors.max

        cells.select { |cell| cell.sweep == :seed_scale && cell.scale_factor == largest }
             .reject { |cell| cell.median_records.nil? }
             .to_h { |cell| [cell.endpoint_key, cell.median_records] }
      end

      private

      def endpoint_to_h(outcome)
        key = outcome.endpoint.to_s

        outcome.to_h.merge(
          endpoint: key,
          findings: outcome.findings.map { |finding| finding.respond_to?(:to_h) ? finding.to_h : finding },
          correlation: correlations[key],
          # Per cell, and each carrying its own sample count: a percentile without the
          # sample size behind it is not something a reader can judge.
          latency: Array(latency[key]).map(&:to_h),
          explain: explain[key]&.to_h,
          time_breakdown: time_breakdown_for(key),
          cold_warm: cold_warm[key]&.to_h
        ).compact
      end

      # The breakdown always travels with the disclosure. Someone reading one endpoint's
      # section must not have to remember what the run header said about containment.
      # nil rather than an empty array when nothing was diagnosed: `.compact` then drops
      # the key entirely, so a clean run's metadata does not carry an empty "traffic"
      # section a reader has to interpret.
      def traffic_to_h
        diagnoses = Array(traffic).map { |diagnosis| diagnosis.respond_to?(:to_h) ? diagnosis.to_h : diagnosis }

        diagnoses.empty? ? nil : diagnoses
      end

      def time_breakdown_for(key)
        breakdown = time_breakdowns[key]
        return nil if breakdown.nil?

        breakdown = breakdown.respond_to?(:to_h) ? breakdown.to_h : breakdown
        breakdown.merge(containment: containment_disclosure&.to_h)
      end

      def confidence_rank(finding)
        order = { high: 0, medium: 1, low: 2, none: 3 }
        confidence = finding.respond_to?(:confidence) ? finding.confidence : :medium

        order.fetch(confidence, 1)
      end

      # Recorded so two runs can be told apart, and so a finding can be traced back to
      # the code that produced it. Absent rather than guessed when this is not a git
      # checkout.
      def git_sha
        return @git_sha if defined?(@git_sha)

        @git_sha = begin
          sha = `git rev-parse --short HEAD 2>/dev/null`.strip
          sha.empty? ? nil : sha
        rescue StandardError
          nil
        end
      end
    end
  end
end

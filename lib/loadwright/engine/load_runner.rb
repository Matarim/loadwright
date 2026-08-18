# frozen_string_literal: true

require "loadwright/errors"
require "loadwright/endpoint_outcome"
require "loadwright/execution/request"
require "loadwright/analysis/response_correlator"
require "loadwright/analysis/response_validator"
require "loadwright/analysis/serializer_attribution"
require "loadwright/reporting/run_result"

module Loadwright
  module Engine
    # Drives the matrix and turns responses into outcomes.
    #
    # ===========================================================================
    # TWO SWEEPS, ONE AXIS FIXED IN EACH. This is the shape decision, not an
    # implementation detail (response-analysis.md Part 2):
    #
    #   SEED-SCALE  vary scale_factors, page size FIXED
    #               -> does query COST grow with table size? (index and scan
    #                  behaviour; this is what pairs with EXPLAIN)
    #
    #   PAGE-SIZE   vary page_size_sweep, seed scale FIXED at the maximum
    #               -> does query COUNT grow with records returned? (the N+1)
    #
    # NEVER BOTH IN ONE SWEEP. If seeded rows and page size both change between
    # cells, a rise in query count cannot be attributed to either, and the slope
    # is unattributable rather than merely noisy.
    #
    # Two consequences of that split, both deliberate:
    #
    #   * The seed-scale sweep sends NO page-size parameter at all. Holding it at an
    #     arbitrary value would be a fixed axis, but not the one a client uses — this
    #     measures the endpoint as it is actually called, which also lets the
    #     unpaginated endpoint reveal its payload growth.
    #
    #   * The page-size sweep runs at concurrency 1. Queries-per-returned-record is a
    #     single-request property, and varying concurrency alongside page size would
    #     reintroduce exactly the unattributable-slope problem the split exists to
    #     avoid.
    # ===========================================================================
    class LoadRunner
      # One cell of the matrix. Records the concurrency it ACTUALLY ran at, which may
      # be lower than requested after a guard step-down — a report must never present
      # a stepped-down result as though it ran at the requested level.
      Cell = Struct.new(
        :endpoint_key, :sweep, :scale_factor, :page_size, :requested_concurrency,
        :actual_concurrency, :requests, :latencies, :query_counts, :record_counts,
        :bytes, :statuses, :errors, :contention_events, :capability_epoch,
        :skipped_reason, :duplicates, :shape, :db_runtimes, :tables,
        keyword_init: true
      ) do
        def stepped_down? = !actual_concurrency.nil? && actual_concurrency != requested_concurrency

        def skipped? = !skipped_reason.nil?

        def median_records = median(record_counts)
        def median_queries = median(query_counts)
        def median_bytes = median(bytes)

        def to_h
          {
            endpoint: endpoint_key, sweep: sweep, scale_factor: scale_factor, page_size: page_size,
            requested_concurrency: requested_concurrency, actual_concurrency: actual_concurrency,
            stepped_down: stepped_down?, requests: requests,
            latency_ms: { p50: percentile(latencies, 0.5), min: latencies&.min, max: latencies&.max },
            records: median_records, queries: median_queries, bytes: median_bytes,
            statuses: Array(statuses).tally, errors: Array(errors).length,
            contention_events: contention_events, capability_epoch: capability_epoch,
            skipped_reason: skipped_reason, shape: shape
          }.compact
        end

        def median(values)
          usable = Array(values).compact
          return nil if usable.empty?

          percentile(usable, 0.5)
        end

        def percentile(values, fraction)
          usable = Array(values).compact.sort
          return nil if usable.empty?

          usable[((usable.length - 1) * fraction).round]
        end
      end

      # What the CLI prints before a run, so nobody discovers a four-hour sweep by
      # waiting through it (CLAUDE.md corollary 7).
      Estimate = Struct.new(:cells, :requests, :estimated_seconds, :mutating_requests, :backoff_budget,
                            keyword_init: true) do
        def estimated_minutes = (estimated_seconds / 60.0).round(1)

        def to_h
          { cells: cells, requests: requests, estimated_seconds: estimated_seconds.round,
            estimated_minutes: estimated_minutes, mutating_requests: mutating_requests,
            backoff_budget: backoff_budget }
        end
      end

      # Used only for the pre-run estimate, before any latency has been measured. A
      # guess, labelled as one, rather than a refusal to estimate.
      ASSUMED_LATENCY_MS = 25.0

      def initialize(config: Loadwright.configuration, context:, guard: nil, breaker: nil,
                     seeder: nil, identities: nil, resolver: nil, lifecycle: nil, stdout: $stdout)
        @config = config
        @context = context
        @guard = guard
        @breaker = breaker || CircuitBreaker.new(config: config)
        @seeder = seeder
        @identities = identities
        @resolver = resolver
        @lifecycle = lifecycle
        @stdout = stdout
        @warnings = []
        reset!
      end

      attr_reader :cells, :outcomes, :warnings

      # ------------------------------------------------------------ matrix shape

      # Built and returned as data so a spec can assert on the CELLS the engine
      # generates — which is what stops a future change quietly reintroducing a
      # combined matrix whose slope is unattributable.
      def matrix(endpoints)
        endpoints.flat_map { |endpoint| seed_scale_cells(endpoint) + page_size_cells(endpoint) }
      end

      def concurrency_levels
        levels = Array(@config.concurrency_levels).sort

        # :in_process has no server thread pool. Threads inside one process sharing a
        # GVL do not measure anything a user would experience, so the levels are
        # forced to [1] rather than producing numbers that look like capacity data.
        return levels if @config.allow_in_process_threading
        return [1] if @context.transport.name == :in_process

        levels
      end

      # The seed scale the page-size sweep holds fixed. Must be large enough to FILL
      # the largest page: sweeping 5/25/100 against 30 seeded rows measures the same
      # 30 records three times and produces a flat line that means nothing.
      def page_size_sweep_scale = Array(@config.scale_factors).max

      def page_size_sweep_measurable?
        page_size_sweep_scale.to_i >= Array(@config.page_size_sweep).max.to_i
      end

      def page_size_sweep_unmeasurable_reason
        "the page-size sweep needs a seed scale at least as large as the biggest page " \
          "(#{Array(@config.page_size_sweep).max}), but the largest scale factor is " \
          "#{page_size_sweep_scale}. Sweeping page sizes against too little data measures the same rows " \
          "repeatedly and produces a flat line that reads as healthy. Raise scale_factors, or lower " \
          "page_size_sweep."
      end

      def estimate(endpoints)
        planned = matrix(endpoints).reject(&:skipped?)
        requests = planned.sum { |cell| cell.requests + @config.warmup_requests }
        mutating = planned.count { |cell| cell.endpoint_key.start_with?("POST", "PUT", "PATCH", "DELETE") }

        # Concurrency divides wall time; the estimate uses the level each cell will
        # actually attempt.
        seconds = planned.sum do |cell|
          per_cell = cell.requests + @config.warmup_requests
          (per_cell * ASSUMED_LATENCY_MS / 1000.0) / [cell.requested_concurrency, 1].max
        end

        Estimate.new(
          cells: planned.length, requests: requests, estimated_seconds: seconds,
          mutating_requests: mutating * (@config.requests_per_endpoint_per_level + @config.warmup_requests),
          backoff_budget: @guard&.backoff_budget
        )
      end

      # ------------------------------------------------------------------- the run

      def run(endpoints:)
        return dry_run(endpoints) if @context.transport.dry_run

        @started_at = Time.now
        run_seed_scale_sweep(endpoints)
        run_page_size_sweep(endpoints)

        build_result(endpoints, aborted_reason: nil)
      rescue RunAborted => e
        @stdout.puts "loadwright: #{e.message}"
        mark_remaining_skipped(endpoints, e)
        build_result(endpoints, aborted_reason: e.message)
      rescue Interrupted => e
        @stdout.puts "loadwright: interrupted; writing a partial report"
        mark_remaining_skipped(endpoints, e)
        build_result(endpoints, aborted_reason: "interrupted")
      end

      private

      # ------------------------------------------------------------- matrix builders

      def seed_scale_cells(endpoint)
        Array(@config.scale_factors).flat_map do |scale|
          concurrency_levels.map do |concurrency|
            Cell.new(
              endpoint_key: endpoint.to_s, sweep: :seed_scale, scale_factor: scale,
              # Deliberately nil: the seed-scale sweep holds page size fixed by NOT
              # sending the parameter, so the endpoint is measured as clients call it.
              page_size: nil,
              requested_concurrency: concurrency, requests: @config.requests_per_endpoint_per_level,
              latencies: [], query_counts: [], record_counts: [], bytes: [], statuses: [],
              errors: [], contention_events: 0, db_runtimes: [], duplicates: {}, tables: []
            )
          end
        end
      end

      def page_size_cells(endpoint)
        Array(@config.page_size_sweep).map do |page_size|
          Cell.new(
            endpoint_key: endpoint.to_s, sweep: :page_size, scale_factor: page_size_sweep_scale,
            page_size: page_size,
            # Concurrency 1: queries-per-returned-record is a single-request property,
            # and varying concurrency here would make the slope unattributable again.
            requested_concurrency: 1, requests: @config.requests_per_endpoint_per_level,
            latencies: [], query_counts: [], record_counts: [], bytes: [], statuses: [],
            errors: [], contention_events: 0, db_runtimes: [], duplicates: {}, tables: [],
            skipped_reason: page_size_sweep_measurable? ? nil : page_size_sweep_unmeasurable_reason
          )
        end
      end

      # ---------------------------------------------------------------- the sweeps

      # A hard dependency, not an optimisation: the guard's Tier 3 degradation check
      # compares against each endpoint's own concurrency-1 baseline, and there is
      # nothing to compare against if this has not run.
      #
      # Measured AFTER the first seeding pass, not before it. Two reasons, and the first
      # is a bug this ordering fixes: before seeding, a nested endpoint's path parameters
      # cannot resolve, and a failed resolution during baselining marked the endpoint
      # `path_params_unresolved` permanently — even though every real cell afterwards
      # resolved fine. The second is that a latency baseline taken against an empty
      # database is not a useful thing to compare a loaded database against.
      #
      # `baseline: true` keeps a resolution failure here from being recorded as the
      # endpoint's verdict; if it still cannot resolve during a real cell, that is
      # where it gets reported.
      def measure_baselines(endpoints)
        endpoints.each do |endpoint|
          latencies = (1..@config.warmup_requests.clamp(1, 5)).filter_map do
            issue(endpoint, scale: nil, page_size: nil, baseline: true)&.response&.latency_ms
          end

          @guard&.record_baseline_latency(endpoint.to_s, latencies)
        end
      end

      def run_seed_scale_sweep(endpoints)
        seeded = 0
        baselines_measured = false

        Array(@config.scale_factors).sort.each do |scale|
          seeded = seed_up_to(scale, seeded)

          unless baselines_measured
            measure_baselines(endpoints)
            baselines_measured = true
          end

          endpoints.each do |endpoint|
            concurrency_levels.each do |concurrency|
              run_cell(endpoint: endpoint, sweep: :seed_scale, scale: scale, page_size: nil,
                       concurrency: concurrency, seeded: seeded)
            end
          end
        end
      end

      def run_page_size_sweep(endpoints)
        unless page_size_sweep_measurable?
          @warnings << page_size_sweep_unmeasurable_reason
          @stdout.puts "loadwright: skipping the page-size sweep — #{page_size_sweep_unmeasurable_reason}"
          return
        end

        seeded = page_size_sweep_scale

        endpoints.each do |endpoint|
          Array(@config.page_size_sweep).each do |page_size|
            run_cell(endpoint: endpoint, sweep: :page_size, scale: seeded, page_size: page_size,
                     concurrency: 1, seeded: seeded)
          end
        end
      end

      # Incremental, so scale_factors [1, 10, 50] costs 50 inserts rather than 61.
      def seed_up_to(scale, already_seeded)
        return already_seeded if @seeder.nil?
        return already_seeded if scale <= already_seeded

        @seeder.seed!(scale - already_seeded)
        @resolver&.seeded_ids = @seeder.created_ids
        scale
      end

      # -------------------------------------------------------------------- one cell

      def run_cell(endpoint:, sweep:, scale:, page_size:, concurrency:, seeded:)
        return if @guard&.quarantined?(endpoint.to_s)

        @lifecycle&.check_interrupt!
        @breaker.check!

        decision = @guard&.check_cell!(endpoint_key: endpoint.to_s, concurrency: concurrency)
        raise RunAborted.new(decision.reason, rung: :resource_guard) if decision&.abort?

        actual = decision&.concurrency || concurrency

        cell = Cell.new(
          endpoint_key: endpoint.to_s, sweep: sweep, scale_factor: scale, page_size: page_size,
          requested_concurrency: concurrency, actual_concurrency: actual,
          requests: @config.requests_per_endpoint_per_level,
          latencies: [], query_counts: [], record_counts: [], bytes: [], statuses: [],
          errors: [], contention_events: 0, db_runtimes: [], duplicates: {}, tables: [],
          capability_epoch: @context.capability_epoch
        )

        @config.warmup_requests.times { issue(endpoint, scale: scale, page_size: page_size) }

        outcomes = drive(endpoint, page_size: page_size, concurrency: actual, count: cell.requests)
        outcomes.each { |outcome| absorb(cell, endpoint, outcome, actual, seeded) }

        if cell.contention_events.zero?
          @guard&.note_recovery(endpoint.to_s)
        elsif @guard&.quarantined?(endpoint.to_s)
          cell.skipped_reason = "quarantined by the contention guard"
        end

        @cells << cell
        cell
      end

      # Real threads, so :http concurrency means something. In :in_process the level is
      # forced to 1, so this is a plain loop there.
      def drive(endpoint, page_size:, concurrency:, count:)
        return Array.new(count) { issue(endpoint, scale: nil, page_size: page_size) }.compact if concurrency <= 1

        results = Queue.new
        per_thread = (count.to_f / concurrency).ceil

        threads = Array.new(concurrency) do
          Thread.new do
            per_thread.times do
              @lifecycle&.check_interrupt!
              results << issue(endpoint, scale: nil, page_size: page_size)
            rescue Interrupted
              break
            end
          end
        end
        threads.each(&:join)

        Array.new(results.length) { results.pop }.compact
      end

      def issue(endpoint, scale:, page_size:, baseline: false)
        resolution = @resolver&.resolve(endpoint)

        if resolution.is_a?(Discovery::PathParamResolver::Unresolved)
          record_unresolved(endpoint, resolution) unless baseline
          return nil
        end

        @context.issue(build_request(endpoint, resolution, page_size))
      end

      def build_request(endpoint, resolution, page_size)
        query = {}
        # The page-size parameter name is whatever the app accepts; the first
        # configured candidate is used, and an endpoint that ignores it shows up as
        # "unable to vary result size" rather than as flat.
        query[@config.page_size_parameters.first] = page_size if page_size

        Execution::Request.new(
          verb: endpoint.verb,
          path: resolution&.path || endpoint.path,
          query: query,
          headers: @identities&.headers_for_next || {},
          body: endpoint.request_body,
          endpoint_key: endpoint.to_s
        )
      end

      def absorb(cell, endpoint, outcome, concurrency, seeded)
        response = outcome.response
        metrics = outcome.metrics

        cell.latencies << response.latency_ms
        cell.statuses << response.status
        cell.bytes << response.body_bytes
        cell.capability_epoch = outcome.capability_epoch

        cell.query_counts << metrics.query_count.value_or(nil)
        cell.db_runtimes << metrics.db_runtime_ms.value_or(nil)

        # The WORST SINGLE REQUEST, not the total across requests. Concatenating turned
        # "the same query ran 26 times in a single request" into "ran 1170 times",
        # which is both false and unbelievable — and a number a reader cannot trust is
        # worse than a smaller true one.
        metrics.duplicate_fingerprints.each do |fingerprint, occurrences|
          existing = cell.duplicates[fingerprint]
          cell.duplicates[fingerprint] = occurrences if existing.nil? || occurrences.length > existing.length
        end

        # EVERY queried table, not just the duplicated ones. Sourcing this from
        # `duplicates` was wrong in a way that inverted the over-fetch signal: a clean
        # endpoint has no duplicate fingerprints, so it looked as though no tables had
        # been queried at all, and the over-fetch class came back UNCOVERED — turning
        # the healthiest endpoints inconclusive.
        metrics.queries.each do |query|
          table = table_in(query[:fingerprint])
          cell.tables << table if table && !cell.tables.include?(table)
        end

        verdict = validator.validate(
          endpoint: endpoint, response: response, seeded_count: seeded_count_for(endpoint, seeded)
        )
        cell.record_counts << verdict.record_count
        cell.shape ||= verdict.shape
        (@verdicts[endpoint.to_s] ||= []) << verdict

        classify_error(cell, endpoint, response, concurrency)
      end

      # How many rows exist FOR THIS ENDPOINT'S resource, which is what the
      # empty-response check needs. Returns nil — meaning "unknown", so the check does
      # not fire — when the resource is not in factory_map at all.
      #
      # Passing the global scale factor instead produced a specific false positive: an
      # endpoint whose resource was never seeded returns an empty collection quite
      # correctly, and was reported as "data was seeded but nothing came back, so your
      # scope is wrong". The developer then goes hunting a scoping bug that does not
      # exist, which costs more than the missing signal would have.
      def seeded_count_for(endpoint, fallback)
        return fallback if @seeder.nil?

        resource = endpoint.resource_name
        return nil if resource.nil?

        ids = @seeder.created_ids
        counted = ids[resource] || ids[resource.to_sym]
        return counted.length if counted

        # Seeded something, but nothing for this resource: an empty response here is
        # expected, not a scope mismatch.
        ids.empty? ? fallback : nil
      end

      # The breaker/guard split, applied per request. A contention error is routed to
      # the guard and EXCLUDED from the breaker's error-rate numerator.
      def classify_error(cell, endpoint, response, concurrency)
        unless response.errored? || response.status.to_i >= 500
          @breaker.record_success
          return
        end

        classification = @guard&.classify(response.error, concurrency: concurrency) || :other

        case classification
        when :contention
          cell.contention_events += 1
          @breaker.record_contention
          decision = @guard.observe(endpoint_key: endpoint.to_s, concurrency: concurrency, error: response.error)
          raise RunAborted.new(decision.reason, rung: :resource_guard) if decision.abort?
        when :endpoint_finding
          @breaker.record_error
          cell.errors << response.error
          @guard.observe(endpoint_key: endpoint.to_s, concurrency: concurrency, error: response.error)
        else
          @breaker.record_error
          cell.errors << (response.error || "HTTP #{response.status}")
        end
      end

      def record_unresolved(endpoint, resolution)
        return if @outcomes.any? { |o| o.endpoint == endpoint && o.reason == :path_params_unresolved }

        @outcomes << EndpointOutcome.inconclusive(
          endpoint: endpoint, reason: :path_params_unresolved, detail: resolution.detail,
          capability_epoch: @context.capability_epoch
        )
      end

      # ---------------------------------------------------------------- the verdict

      def build_result(endpoints, aborted_reason:)
        endpoints.each { |endpoint| @outcomes << outcome_for(endpoint) unless already_decided?(endpoint) }

        Reporting::RunResult.new(
          config: @config,
          started_at: @started_at,
          finished_at: Time.now,
          context: @context,
          cells: @cells,
          outcomes: @outcomes,
          correlations: @correlations,
          breaker: @breaker,
          guard: @guard,
          seeder: @seeder,
          identities: @identities,
          warnings: @warnings,
          aborted_reason: aborted_reason
        )
      end

      def outcome_for(endpoint)
        key = endpoint.to_s
        cells = @cells.select { |cell| cell.endpoint_key == key }
        verdicts = @verdicts.fetch(key, [])

        return skipped_outcome(endpoint) if cells.empty?

        # The validity gate comes first, always. No performance verdict is attached to
        # a response that did not prove it did the work.
        invalid = verdicts.find { |verdict| !verdict.valid? }
        return inconclusive(endpoint, invalid.reason, invalid.detail) if invalid

        shapes = cells.map(&:shape)
        unless validator.consistent_shape?(shapes)
          return inconclusive(endpoint, :inconsistent_shape, validator.shape_inconsistency_detail(shapes))
        end

        return inconclusive(endpoint, :quarantined, quarantine_detail(key)) if @guard&.quarantined?(key)

        findings = findings_for(endpoint, cells)
        @correlations[key] = correlator.to_h(observations_for(cells))

        # The state comes from finding-class COVERAGE, not from how many signals
        # happened to produce a number. EndpointOutcome.derive owns the precedence so
        # reporting renders a state rather than recomputing one.
        EndpointOutcome.derive(
          endpoint: endpoint,
          findings: findings,
          coverage: coverage_for(cells),
          capability_epoch: cells.last.capability_epoch
        )
      end

      # Coverage is computed per endpoint from the detectors that actually ran, and is
      # attached to EVERY outcome regardless of state — a reader can then see that an
      # otherwise-clean endpoint was checked with one N+1 detector instead of two,
      # without `inconclusive` having to be overloaded to signal it.
      def coverage_for(cells)
        measured = cells.reject(&:skipped?)
        page_size_cells = measured.select { |cell| cell.sweep == :page_size }
        seed_scale_cells = measured.select { |cell| cell.sweep == :seed_scale }

        Coverage.new(
          correlator.detector_states(
            # The N+1 detectors read the page-size sweep where there is one, since that
            # is the sweep that varies returned records.
            observations: observations_for(page_size_cells.empty? ? seed_scale_cells : page_size_cells),
            query_data: measured.any? { |cell| cell.query_counts.compact.any? },
            tables_queried: tables_queried(measured)
          ).merge(
            payload_growth: payload_growth_state(seed_scale_cells)
          )
        )
      end

      # Payload growth is measured against SEEDED rows, so its coverage comes from the
      # seed-scale sweep specifically — asking the page-size sweep would report it
      # unmeasurable on every endpoint, since that sweep holds seed scale fixed by
      # design.
      #
      # A run configured with ONE scale factor is :not_applicable, not :unavailable.
      # The line between the two is who prevented the answer: :unavailable means the
      # app or its data did (result size could not be varied, no query data came back),
      # :not_applicable means the run was never asked to look. A single scale factor is
      # the user declining to sweep, exactly like detect_overfetching = false — and
      # treating it as a gap would turn every endpoint of a deliberately-narrow run
      # inconclusive, which is the flooding the coverage rule exists to prevent.
      def payload_growth_state(seed_scale_cells)
        if Array(@config.scale_factors).uniq.length < 2
          return [:not_applicable,
                  "only one scale factor is configured (#{Array(@config.scale_factors).join(', ')}), " \
                  "so payload growth against table size cannot be measured; add a second to " \
                  "config.scale_factors"]
        end

        growth = correlator.payload_growth(observations_for(seed_scale_cells))

        growth.available? ? :available : [:unavailable, growth.reason]
      end

      # The tables recorded during the run, for the over-fetch comparison.
      def tables_queried(cells) = cells.flat_map { |cell| Array(cell.tables) }.uniq

      def table_in(fingerprint)
        fingerprint.to_s[/(?:FROM|JOIN)\s+[`"']?([A-Za-z0-9_]+)/i, 1]
      end

      def findings_for(endpoint, cells)
        # The two sweeps answer different questions, so their observations are fed to
        # the correlator separately — the whole point of holding one axis fixed in each.
        page_size_cells = cells.select { |cell| cell.sweep == :page_size && !cell.skipped? }
        seed_scale_cells = cells.select { |cell| cell.sweep == :seed_scale && !cell.skipped? }

        duplicates = cells.each_with_object({}) do |cell, out|
          Array(cell.duplicates).each { |fingerprint, occurrences| (out[fingerprint] ||= []).concat(occurrences) }
        end

        findings = correlator.findings(
          observations: observations_for(page_size_cells.empty? ? seed_scale_cells : page_size_cells),
          duplicates: duplicates
        )
        findings.concat(correlator.findings(observations: observations_for(seed_scale_cells)).select do |finding|
          %i[missing_pagination oversized_payload].include?(finding.kind)
        end)

        findings.concat(Array(@guard&.findings).select { |finding| finding.endpoint_key == endpoint.to_s })

        annotate(findings)
      end

      def annotate(findings)
        findings.each do |finding|
          next unless finding.respond_to?(:detail) && finding.respond_to?(:evidence)

          sentence = attribution.annotate(finding)
          finding.detail = "#{finding.detail} — #{sentence}" if sentence
        end
      end

      def observations_for(cells)
        cells.map do |cell|
          Analysis::ResponseCorrelator::Observation.new(
            label: "#{cell.sweep}/#{cell.scale_factor}/#{cell.page_size || 'default'}",
            records: cell.median_records, queries: cell.median_queries, bytes: cell.median_bytes,
            seeded: cell.scale_factor, page_size: cell.page_size
          )
        end
      end

      def quarantine_detail(key)
        events = Array(@guard&.events).select { |event| event.endpoint_key == key }
        blocker = events.map(&:blocker).uniq.join(", ")

        "abandoned after the backoff ladder; #{events.length} contention event(s), blocker: #{blocker}"
      end

      def already_decided?(endpoint) = @outcomes.any? { |outcome| outcome.endpoint == endpoint }

      def skipped_outcome(endpoint)
        reason = @breaker.tripped? ? :circuit_breaker : :run_aborted

        EndpointOutcome.inconclusive(endpoint: endpoint, reason: reason)
      end

      def inconclusive(endpoint, reason, detail)
        EndpointOutcome.inconclusive(endpoint: endpoint, reason: reason, detail: detail,
                                     capability_epoch: @context.capability_epoch)
      end

      def mark_remaining_skipped(endpoints, error)
        reason = error.is_a?(Interrupted) ? :interrupted : (@breaker.tripped? ? :circuit_breaker : :run_aborted)

        endpoints.reject { |endpoint| already_decided?(endpoint) }.each do |endpoint|
          next if @cells.any? { |cell| cell.endpoint_key == endpoint.to_s }

          @outcomes << EndpointOutcome.inconclusive(endpoint: endpoint, reason: reason)
        end
      end

      # ------------------------------------------------------------------- dry run

      def dry_run(endpoints)
        planned = matrix(endpoints)
        estimate = estimate(endpoints)

        @stdout.puts "loadwright: DRY RUN — resolving the matrix, sending zero requests"
        @stdout.puts format("  %<endpoints>d endpoint(s), %<cells>d cell(s), %<requests>d request(s)",
                            endpoints: endpoints.length, cells: estimate.cells, requests: estimate.requests)
        @stdout.puts format("  estimated %<minutes>.1f minute(s) at an assumed %<latency>dms per request",
                            minutes: estimate.estimated_minutes, latency: ASSUMED_LATENCY_MS)
        @stdout.puts "  #{estimate.mutating_requests} mutating request(s)" if estimate.mutating_requests.positive?
        @stdout.puts "  #{@guard.describe_budget}" if @guard

        planned.group_by(&:endpoint_key).each do |key, cells|
          @stdout.puts "  #{key}"
          cells.group_by(&:sweep).each do |sweep, group|
            skipped = group.select(&:skipped?)
            @stdout.puts "    #{sweep}: #{group.length - skipped.length} cell(s)" \
                         "#{skipped.any? ? " (#{skipped.length} not measurable)" : ''}"
          end
        end

        @cells = planned
        build_result(endpoints, aborted_reason: nil)
      end

      # -------------------------------------------------------------- collaborators

      def validator = @validator ||= Analysis::ResponseValidator.new(config: @config)

      def correlator
        @correlator ||= Analysis::ResponseCorrelator.new(config: @config, capability: @context.capability_profile)
      end

      def attribution = @attribution ||= Analysis::SerializerAttribution.new(config: @config)

      public

      def reset!
        @cells = []
        @outcomes = []
        @verdicts = {}
        @correlations = {}
        self
      end
    end
  end
end

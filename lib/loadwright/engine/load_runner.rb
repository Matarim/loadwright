# frozen_string_literal: true

require "loadwright/errors"
require "loadwright/endpoint_outcome"
require "loadwright/execution/request"
require "loadwright/analysis/response_correlator"
require "loadwright/analysis/response_validator"
require "loadwright/analysis/serializer_attribution"
require "loadwright/analysis/explain_analyzer"
require "loadwright/analysis/statistics"
require "loadwright/analysis/cold_warm"
require "loadwright/analysis/containment_disclosure"
require "loadwright/analysis/traffic_diagnosis"
require "loadwright/analysis/time_breakdown"
require "loadwright/analysis/pool_sizing_check"
require "loadwright/reporting/run_result"

module Loadwright
  module Engine
    # Drives the matrix and turns responses into outcomes.
    #
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
    class LoadRunner
      # One cell of the matrix. Records the concurrency it ACTUALLY ran at, which may
      # be lower than requested after a guard step-down — a report must never present
      # a stepped-down result as though it ran at the requested level.
      # TWO DIFFERENT FACTS, AND ONLY ONE OF THEM IS ABOUT THE USER'S API.
      #
      # "No document operation matched this endpoint" is about our join. "The matched
      # operation declares no response schema" is about their document. Sharing one
      # sentence is how a join defect -- the server base path being ignored -- was
      # reported for a whole API as a property of the API, with the reader pointed at
      # documents that declared a schema for 50 of their 61 operations.
      NO_DOCUMENT_MATCH_NOTE = "not validated: no OpenAPI operation matched this endpoint, so there was " \
                               "no schema to check against. It was discovered from %<sources>s. If you " \
                               "expected a document to describe it, check that the document's path -- " \
                               "including any `servers` base path -- resolves to this template."

      UNRESOLVABLE_NOTE = "not validated: the declared schema could not be loaded (%<error>s). This is a " \
                          "fault in Loadwright, not in your response or your document -- nothing about " \
                          "this endpoint's body was checked, and nothing was concluded from it. Please " \
                          "report it."

      NO_SCHEMA_NOTE = "not validated: an OpenAPI operation matched this endpoint but declares no 2xx " \
                       "response schema, so there is nothing to validate against. Declare one and the " \
                       "check starts running."

      Cell = Struct.new(
        :endpoint_key, :sweep, :scale_factor, :page_size, :requested_concurrency,
        :actual_concurrency, :requests, :latencies, :query_counts, :record_counts,
        :bytes, :statuses, :errors, :contention_events, :capability_epoch,
        :skipped_reason, :duplicates, :shape, :db_runtimes, :tables,
        # The warmup pass, KEPT rather than discarded: cold-cache performance is what
        # users hit right after a deploy, and it is the case nobody measures.
        :cold_latencies, :jobs_enqueued, :view_runtimes, :gc_times,
        # Only the rate-limit headers, not the whole response header set: they are what
        # names a throttled run, and keeping the rest would put arbitrary header values
        # into a persisted record for no signal.
        :rate_limit_headers,
        # The exception the application rescued and rendered, per distinct class.
        # :in_process only -- we are in the same process there and already have it.
        :app_exceptions,
        # Fingerprints of SELECTs that matched no rows, one exemplar each.
        :zero_row_queries,
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
                     seeder: nil, identities: nil, resolver: nil, lifecycle: nil, stdout: $stdout,
                     explain_analyzer: nil, statistics: nil, containment: nil, pool_tracker: nil,
                     cold_warm: nil, run_store: nil, safety_decision: nil, discovery: nil)
        @config = config
        @context = context
        @guard = guard
        @breaker = breaker || CircuitBreaker.new(config: config)
        @seeder = seeder
        @identities = identities
        @resolver = resolver
        @lifecycle = lifecycle
        @stdout = stdout
        @explain_analyzer = explain_analyzer
        @statistics = statistics
        @containment = containment
        @pool_tracker = pool_tracker
        @cold_warm_analyzer = cold_warm
        @run_store = run_store
        # PROVENANCE, not measurement. production-safety.md requires every guard
        # decision to reach the report, so a run's authority to have happened at all
        # is auditable after the fact rather than only in the terminal that is gone.
        # The runner does not consult either of these; it carries them.
        @safety_decision = safety_decision
        @discovery = discovery
        @warnings = []
        @quarantined_keys = []
        # endpoint key -> query parameter names whose recorded value we replayed
        # because nothing seeded could resolve them. Read when a 404 needs explaining.
        @replayed_identifiers = {}
        # endpoint key -> what the request actually carried, and where each value came
        # from. See #request_shape_for.
        @request_shapes = {}
        reset!
        arm_run_history!
      end

      attr_reader :cells, :outcomes, :warnings

      # A PARTIAL RECORD IS OFTEN THE MOST INTERESTING ONE, and `ensure` does not run on
      # a signal. The store registers with Lifecycle -- which owns the one trap -- so a
      # Ctrl-C mid-run still leaves something the next run can be compared against, and
      # something the partial-report path can read.
      #
      # The provider returns nil until there is anything to record, so an interrupt
      # during startup writes no record rather than an empty one that would later read
      # as a run which found nothing.
      def arm_run_history!
        @run_store&.arm! do
          # ONLY WHEN #run NEVER RETURNED. A run that finished -- normally, or by
          # rescuing an abort and building a partial result -- hands its result to the
          # caller, who persists it. Firing here as well wrote a SECOND record marked
          # "interrupted" for every completed run, which then showed up in `runs list`
          # and made every comparison warn that a healthy run had been aborted.
          next nil if @completed
          next nil if @cells.empty? && @outcomes.empty?

          # ASSEMBLE, do not build: #build_result persists, and RunStore#arm! persists
          # what this block returns. Calling the persisting one here wrote the record
          # twice.
          assemble_result(@endpoints || [], aborted_reason: "interrupted")
        end
      end

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
        # Asks the ENDPOINT, not its key. Matching "POST" against the key counted every
        # GraphQL query as a write -- they are all POSTs -- and announced a hundred
        # mutating requests before a run that issued none.
        mutating_keys = endpoints.select(&:mutating?).map(&:to_s)
        mutating = planned.count { |cell| mutating_keys.include?(cell.endpoint_key) }

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
        # Held so the interrupt path can build a result for the endpoints this run was
        # actually asked about, rather than for an empty list.
        @endpoints = endpoints
        # So the breaker's spread check counts the surface rather than whichever
        # endpoints the matrix happened to reach first. See CircuitBreaker
        # #expected_endpoints.
        @breaker.expected_endpoints = endpoints.length
        return dry_run(endpoints) if @context.transport.dry_run

        @started_at = Time.now

        # BEFORE ANY REQUEST GOES OUT. Nothing called this, so a configured
        # auth_token_provider was built into a pool, handed here, and never resolved:
        # `headers_for_next` returned {} and every request went out unauthenticated.
        # The run then reported every endpoint 401/403 and told the user their token
        # was probably misconfigured -- the tool's own doing, and the single most
        # common first-run failure it documents.
        resolve_identities!

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

      # THE SAME CONTRACT AS RunStore#arm!, for reports rather than history: the
      # caller writes the report when #run returns, and this covers only the case
      # where it never did. `@completed` is what distinguishes them, so a run that
      # finished -- normally or by rescuing an abort -- never produces a second,
      # partial report alongside its real one.
      #
      # Returns nil when there is nothing yet to report, because an empty report
      # written by an interrupt during startup reads as an API where nothing was
      # found rather than as a run that never began.
      def resolve_identities!
        return if @identities.nil?

        # The transport is only used when config.auth_login is set, which issues a real
        # login request through the same path the run itself uses.
        @identities.resolve!(transport: @context.transport)
        @identities.warnings.each { |warning| @stdout.puts "loadwright: #{warning}" }
      end

      def partial_result
        return nil if @completed
        return nil if @cells.empty? && @outcomes.empty?

        assemble_result(@endpoints || [], aborted_reason: "interrupted")
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
              errors: [], contention_events: 0, db_runtimes: [], duplicates: {}, tables: [],
              cold_latencies: [], jobs_enqueued: [], rate_limit_headers: {}, view_runtimes: [], gc_times: []
            )
          end
        end
      end

      # ASK THE ENDPOINT WHAT IT ACCEPTS, where its document says so.
      #
      # A page size the sweep chose that the endpoint rejects is our doing -- 0.0.7
      # added a whole outcome reason to say so, which was the right response to the
      # symptom and not to the cause. An enum on the page-size parameter names the legal
      # values exactly, and reading it turns a fabricated inconsistency into a real
      # measurement. One integration lost most of a round explaining a 400 band that
      # existed only because the default sweep guessed outside a declared set.
      #
      # Only values the run could support: a declared size larger than the seeded scale
      # would measure the same rows repeatedly, which is the flat line that reads as
      # healthy.
      def sweep_values_for(endpoint)
        configured = Array(@config.page_size_sweep)
        declared = endpoint.respond_to?(:declared_page_sizes) &&
                   endpoint.declared_page_sizes(@config.page_size_parameters)
        return configured unless declared&.any?

        usable = declared.select { |size| size <= page_size_sweep_scale.to_i }
        return configured if usable.empty?

        @warnings << "#{endpoint} declares the page sizes it accepts (#{declared.join(', ')}), so the " \
                     "sweep used #{usable.join(', ')} instead of the configured " \
                     "#{configured.join(', ')}. A page size the sweep chose that the endpoint rejects " \
                     "is our doing, not yours."
        @warnings.uniq!
        usable
      end

      # Run-level first, then per-endpoint: a GraphQL operation with no page-size
      # variable cannot be swept even when the run as a whole can.
      def page_size_cell_skip_reason(endpoint)
        return page_size_sweep_unmeasurable_reason unless page_size_sweep_measurable?

        endpoint.page_size_unavailable_reason
      end

      def skip_page_size_sweep?(endpoint)
        return false if endpoint.page_size_varying?

        @warnings << endpoint.page_size_unavailable_reason
        @stdout.puts "loadwright: #{endpoint} — #{endpoint.page_size_unavailable_reason}"
        true
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
            cold_latencies: [], jobs_enqueued: [], rate_limit_headers: {}, view_runtimes: [], gc_times: [],
            skipped_reason: page_size_cell_skip_reason(endpoint)
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

      # THE DRY RUN IS WHERE A CONFIGURATION PROBLEM SHOULD SURFACE. Discovering after
      # a completed run that half the N+1 detection never executed is late; after a
      # forty-minute one it is expensive. The seed-scale sweep on its own cannot catch
      # an N+1 hiding behind pagination -- that is the whole reason the page-size sweep
      # exists -- so every paginated endpoint in the healthy list has had one of two
      # detectors applied to it. Coverage#describe says so per endpoint; this says it
      # before the run rather than after.
      def warn_about_unmeasurable_page_size_sweep
        return if page_size_sweep_measurable?

        @warnings << page_size_sweep_unmeasurable_reason
        @stdout.puts "loadwright: the page-size sweep will NOT run — #{page_size_sweep_unmeasurable_reason}"
        @stdout.puts "  That is one of the two N+1 detectors. The other (duplicate-fingerprint pattern " \
                     "matching) still runs, so endpoints are still checked — with half the coverage, " \
                     "which each endpoint's `checked:` line will say."
      end

      def run_page_size_sweep(endpoints)
        unless page_size_sweep_measurable?
          @warnings << page_size_sweep_unmeasurable_reason
          @stdout.puts "loadwright: skipping the page-size sweep — #{page_size_sweep_unmeasurable_reason}"
          return
        end

        seeded = page_size_sweep_scale

        endpoints.each do |endpoint|
          next if skip_page_size_sweep?(endpoint)

          sweep_values_for(endpoint).each do |page_size|
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
        # path_values, not created_ids: what the API routes on, which is the primary
        # key unless factory_map named another column.
        @resolver&.seeded_ids = @seeder.path_values
        scale
      end

      # -------------------------------------------------------------------- one cell

      def run_cell(endpoint:, sweep:, scale:, page_size:, concurrency:, seeded:)
        return if @guard&.quarantined?(endpoint.to_s)
        return record_error_quarantine(endpoint) if @quarantined_keys.include?(endpoint.to_s)

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
          cold_latencies: [], jobs_enqueued: [], rate_limit_headers: {}, view_runtimes: [], gc_times: [],
          capability_epoch: @context.capability_epoch
        )

        # THE WARMUP PASS IS RECORDED, not discarded. It is still excluded from the
        # steady-state figures -- that is what warmup is for -- but the first requests
        # after clearing the application cache are the only cold measurement this run
        # will ever get, and throwing them away throws away the endpoint's worst case.
        cleared = prepare_cold_pass(endpoint)
        @config.warmup_requests.times do
          outcome = issue(endpoint, scale: scale, page_size: page_size)
          cell.cold_latencies << outcome.response.latency_ms if outcome
        end

        outcomes = drive(endpoint, page_size: page_size, concurrency: actual, count: cell.requests)
        outcomes.each { |outcome| absorb(cell, endpoint, outcome, actual, seeded) }

        # Compared AFTER the measured requests, since the warm half comes from them.
        record_cold_warm(endpoint, cell, cleared)

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
      #
      # THE SINGLE-THREADED PATH CHECKS FOR INTERRUPTION TOO, and it is the one that
      # matters most: concurrency 1 is the default, and it is forced under :in_process.
      # Without the check, Ctrl-C did not stop the request loop until the whole cell
      # finished -- so with 200 requests per cell the run kept hammering a server
      # Lifecycle teardown had already killed, and the resulting wall of connection
      # errors tripped the CIRCUIT BREAKER. The run then reported itself aborted for
      # an error rate rather than interrupted, which is a false account of what
      # happened and blames the app for the user pressing Ctrl-C.
      def drive(endpoint, page_size:, concurrency:, count:)
        if concurrency <= 1
          return Array.new(count) do
            @lifecycle&.check_interrupt!
            issue(endpoint, scale: nil, page_size: page_size)
          end.compact
        end

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

      # WHAT WE ACTUALLY SENT, AND WHERE EACH VALUE CAME FROM.
      #
      # Two separate failures in one round traced back to the report never saying this.
      #
      # An endpoint answered 404 and the reader had no way to tell whether we had sent
      # it a resolved id or a placeholder lifted from a spec -- the difference between
      # their bug and ours.
      #
      # And an endpoint that had been measured at 73 queries and 250ms was reported
      # HEALTHY in the next run, because a change in the recording meant it was no
      # longer sent the parameter that selects its expensive representation. The two
      # runs asked it different questions and nothing in either report said so. A
      # confirmed defect un-found itself, silently.
      #
      # The shape is cheap to record, belongs on the endpoint rather than in a log, and
      # is what History::Comparator needs to refuse a comparison between two runs that
      # asked different questions.
      def request_shape_for(key) = @request_shapes[key]

      # THE VALUES, NOT ONLY WHERE THEY CAME FROM.
      #
      # Provenance alone answers "is this 404 ours or theirs" and does not answer "what
      # did you actually ask it". Those are different questions and the second one
      # decides what a finding MEANS: an endpoint taking a `view` parameter issues 3
      # queries at its default and 147 at another value, so a repeat count with no
      # mention of the value is a property of one parameterisation reported as a
      # property of the endpoint. One integration spent a full code trace establishing
      # that, having first concluded the tool was wrong.
      #
      # The values go through the redactor on the way into a persisted record, which is
      # where the app's own filter_parameters are honoured.
      def note_request_shape(endpoint, request, sources, resolution = nil)
        key = endpoint.to_s
        return if @request_shapes.key?(key)

        query = Hash(request.query)
        @request_shapes[key] = {
          path: request.path,
          # WHICH SOURCE WON, PER PATH SEGMENT. A seeded value losing to a recorded
          # literal is invisible otherwise: the path looks fine, the run says nothing,
          # and finding out costs a probe plus a cross-round diff.
          path_values: Hash(resolution&.sources).to_h { |name, source| [name, source] },
          query: sources.to_h { |name, source| [name, { source: source, value: query[name] }] },
          headers: request.headers.keys.reject { |name| name.to_s.downcase == "authorization" }.sort
        }
      end

      def build_request(endpoint, resolution, page_size)
        sources = {}
        query = recorded_query_for(endpoint, sources)
        # The page-size parameter name is whatever the app accepts; the first
        # configured candidate is used, and an endpoint that ignores it shows up as
        # "unable to vary result size" rather than as flat.
        if page_size
          query[@config.page_size_parameters.first] = page_size
          sources[@config.page_size_parameters.first] = :page_size_sweep
        end

        request = Execution::Request.new(
          verb: endpoint.verb,
          path: resolution&.path || endpoint.path,
          query: query,
          # The identity's headers go LAST and win. A recorded Authorization header is
          # redacted to a placeholder on the way into the recording anyway, and even a
          # real one belongs to whoever ran the specs, not to this run.
          # The PATH goes in, so a second mount authenticated differently gets its own
          # credential. Without it one auth_strategy covered an application that has
          # two, and the mount it did not cover failed on every request.
          headers: recorded_headers_for(endpoint)
                     .merge(@identities&.headers_for_next(path: resolution&.path || endpoint.path) || {}),
          body: endpoint.body_for(page_size),
          endpoint_key: endpoint.to_s
        )
        note_request_shape(endpoint, request, sources, resolution)
        request
      end

      # WHAT A PASSING SPEC ACTUALLY SENT. Discovery collects the query parameters of
      # the richest recorded request and the run then sent none of them, so an endpoint
      # with a required parameter answered 400 on every request and was marked
      # inconclusive -- coverage lost to the reconstruction, not to the app, with the
      # information needed to build a valid request sitting in a file we wrote.
      #
      # A recorded PAGE SIZE is dropped, whichever sweep is running. The seed-scale
      # sweep deliberately sends no page-size parameter, so the endpoint is measured
      # the way clients call it; the page-size sweep sets its own. Replaying a recorded
      # per_page would pin the axis the sweep exists to vary, and the result would read
      # as a flat, healthy line.
      def recorded_query_for(endpoint, sources = {})
        return {} unless @config.replay_recorded_query_params

        page_size_names = Array(@config.page_size_parameters).map(&:to_s)
        Array(endpoint.query_params).each_with_object({}) do |param, out|
          name = param[:name].to_s
          next if name.empty? || page_size_names.include?(name)
          next if param[:example].nil?

          out[name] = query_value_for(endpoint, name, param[:example], sources)
        end
      end

      # AN IDENTIFIER IN A QUERY STRING IS STILL AN IDENTIFIER. A recorded id in the
      # PATH is the weakest evidence in a four-source chain, behind an override and a
      # seeded row, because a spec's ids do not exist in the database being measured.
      # The same id in a query string was replayed as fact -- so a placeholder went out
      # verbatim, matched nothing, and the endpoint answered 404 as though it were
      # broken.
      #
      # A seeded value wins where there is one. Where there is not, the recorded value
      # still goes -- dropping a required parameter trades a 404 for a 400 and loses
      # the endpoint either way -- but the endpoint is MARKED, so a 404 can say the
      # request carried an identifier we could not resolve rather than presenting it as
      # the app's answer.
      def query_value_for(endpoint, name, recorded, sources = {})
        unless @resolver.respond_to?(:identifier_shaped?) && @resolver.identifier_shaped?(name)
          sources[name] = :recorded
          return recorded
        end

        seeded = @resolver.resolve_query_param(name)
        unless seeded.nil?
          sources[name] = :seeded
          return seeded
        end

        sources[name] = :recorded_identifier
        (@replayed_identifiers[endpoint.to_s] ||= []) << name
        @replayed_identifiers[endpoint.to_s].uniq!
        recorded
      end

      # By name, not wholesale: a recording holds the whole content-negotiation and
      # custom-header set, and replaying a Host or a request id would be wrong.
      def recorded_headers_for(endpoint)
        wanted = Array(@config.replay_recorded_headers).map { |name| name.to_s.downcase }
        return {} if wanted.empty?

        Hash(endpoint.recorded_headers).each_with_object({}) do |(name, value), out|
          out[name.to_s] = value if wanted.include?(name.to_s.downcase) && !value.nil?
        end
      end

      def absorb(cell, endpoint, outcome, concurrency, seeded)
        response = outcome.response
        metrics = outcome.metrics

        cell.latencies << response.latency_ms
        cell.statuses << response.status
        record_rate_limit_headers(cell, response)
        cell.bytes << response.body_bytes
        cell.capability_epoch = outcome.capability_epoch

        cell.query_counts << metrics.query_count.value_or(nil)
        cell.db_runtimes << metrics.db_runtime_ms.value_or(nil)
        cell.jobs_enqueued << metrics.jobs_enqueued.value_or(nil)
        cell.view_runtimes << metrics.view_runtime_ms.value_or(nil)
        cell.gc_times << metrics.gc_time_ms.value_or(nil)

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
        # THE SETTING PROMISES SOMETHING WE CANNOT ALWAYS DELIVER. Rails' own
        # QueryCache middleware enables the cache per request, after our setup-time
        # disable, so a cached query arriving here means the disable did not hold --
        # and every N+1 count in the run is then a count of what EXECUTED rather than
        # of what the code asked for. Undercounting is exactly what the setting exists
        # to prevent, so it is reported rather than left to be discovered.
        @query_cache_observed ||= metrics.queries.any? { |query| query[:cached] }

        # THE QUERY THAT FOUND NOTHING. An endpoint that 404s or returns [] against a
        # seeded database did so because some query matched no rows, and until now the
        # report said only that scope had excluded the data -- without saying which
        # scope, which is the half a reader can act on. Kept as one exemplar
        # fingerprint, not per request: a hundred requests failing the same way is one
        # fact.
        cell.zero_row_queries ||= []
        metrics.queries.each do |query|
          if query[:row_count]&.zero? && select?(query[:fingerprint]) &&
             !cell.zero_row_queries.include?(query[:fingerprint])
            cell.zero_row_queries << query[:fingerprint]
          end
        end

        metrics.queries.each do |query|
          table = table_in(query[:fingerprint])
          cell.tables << table if table && !cell.tables.include?(table)

          # Rows the APP created answering this request. Read off the fingerprints
          # already being collected, which works in BOTH modes without new plumbing:
          # under :http the query data has crossed the collection endpoint from the
          # app's own process, and a table name survives normalisation even though the
          # values do not.
          @seeder&.note_request_written_table(inserted_table_in(query[:fingerprint]))

          remember_slow_query(endpoint.to_s, query)
        end

        note_app_exception(cell, response)

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
          @breaker.record_success(endpoint.to_s)
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
          @breaker.record_error(endpoint.to_s)
          cell.errors << response.error
          @guard.observe(endpoint_key: endpoint.to_s, concurrency: concurrency, error: response.error)
        else
          @breaker.record_error(endpoint.to_s)
          cell.errors << (response.error || "HTTP #{response.status}")
        end

        quarantine_if_concentrated!
      end

      # One endpoint owning nearly all the errors means that endpoint is broken, not
      # the run. Set it aside and keep measuring the others, rather than aborting and
      # losing every endpoint the sweep had not reached yet.
      def quarantine_if_concentrated!
        key = @breaker.quarantine_candidate
        return if key.nil? || @quarantined_keys.include?(key)

        @quarantined_keys << key
        @breaker.quarantine!(key)
        @stdout.puts "loadwright: #{key} is failing on nearly every request; quarantining it and " \
                     "continuing with the rest of the run"
      end

      # Inconclusive, never healthy: the endpoint failed on nearly every request, and
      # what remains unmeasured about it is unmeasured.
      #
      # LEADS WITH THE SAME SENTENCE THE VALIDITY GATE USES, because it is the same
      # situation: every request came back a non-success status. Which mechanism
      # noticed -- the gate, or the error-concentration quarantine -- is an
      # implementation detail, and reporting it as two differently-worded outcomes
      # sent a reader looking for a distinction that does not exist. The distinction
      # survives where it is useful: the reason SYMBOL is still :endpoint_erroring in
      # the machine-readable output.
      def record_error_quarantine(endpoint)
        return if @outcomes.any? { |o| o.endpoint == endpoint && o.reason == :endpoint_erroring }

        @outcomes << EndpointOutcome.inconclusive(
          endpoint: endpoint, reason: :endpoint_erroring,
          detail: "#{erroring_status_phrase(endpoint)}. An error path was measured, not the endpoint. " \
                  "It failed on nearly every request, so it was quarantined and the rest of the run " \
                  "continued without it." \
                  "#{failure_notes_for(endpoint)}",
          capability_epoch: @context.capability_epoch
        )
      end

      # The status the endpoint actually answered with, where any request got far
      # enough to have one.
      def erroring_status_phrase(endpoint)
        statuses = @cells.select { |cell| cell.endpoint_key == endpoint.to_s }
                         .flat_map { |cell| Array(cell.statuses) }.compact
        return "every request failed" if statuses.empty?

        dominant = statuses.tally.max_by { |_, count| count }.first
        "returned HTTP #{dominant}"
      end

      def record_unresolved(endpoint, resolution)
        return if @outcomes.any? { |o| o.endpoint == endpoint && o.reason == :path_params_unresolved }

        @outcomes << EndpointOutcome.inconclusive(
          endpoint: endpoint, reason: :path_params_unresolved,
          detail: "#{resolution.detail}#{rejection_only_note(endpoint)}",
          capability_epoch: @context.capability_epoch
        )
      end

      # ---------------------------------------------------------------- the verdict

      # PERSISTED HERE, not left to the caller. "An interrupted run still leaves a
      # usable record" cannot depend on a caller remembering to write one -- the
      # interrupted caller is precisely the one that did not get that far. The runner
      # has the result, so the runner stores it, and the Lifecycle-armed hook is left
      # covering only the case where #run never returned at all.
      #
      # A DRY RUN IS NOT PERSISTED. It issues no requests, so a record of one would be a
      # run of zeroes sitting in history waiting to be compared against something real.
      def build_result(endpoints, aborted_reason:)
        result = assemble_result(endpoints, aborted_reason: aborted_reason)
        @run_store&.write!(result) unless @context.transport.dry_run
        # Set HERE and not in an `ensure` around #run: `ensure` also fires when an
        # exception is propagating, which is the one case the Lifecycle-armed record
        # exists for. Marking the run complete there disarmed the hook exactly when it
        # was needed.
        @completed = true
        result
      end

      def assemble_result(endpoints, aborted_reason:)
        run_post_load_analysis(endpoints)
        endpoints.each { |endpoint| @outcomes << outcome_for(endpoint) unless already_decided?(endpoint) }

        Reporting::RunResult.new(
          config: @config,
          started_at: @started_at,
          finished_at: Time.now,
          context: @context,
          cells: @cells,
          outcomes: @outcomes,
          correlations: @correlations,
          request_shapes: @request_shapes,
          schema_validation: @schema_validation,
          breaker: @breaker,
          guard: @guard,
          seeder: @seeder,
          identities: @identities,
          warnings: @warnings + query_cache_warnings + resolver_warnings,
          aborted_reason: aborted_reason,
          explain: @explain,
          latency: @latency,
          cold_warm: @cold_warm,
          time_breakdowns: @time_breakdowns,
          traffic: @traffic,
          pool_sizing: pool_sizing,
          containment: @containment,
          safety_decision: @safety_decision,
          discovery: @discovery,
          containment_disclosure: containment_disclosure
        )
      end

      # ------------------------------------------------- the phase AFTER the load
      #
      # EXPLAIN runs here and nowhere else. performance-signals.md is explicit that it
      # must not run during the load phase: it issues real queries on a real
      # connection, and doing that while measuring latency would make the tool part of
      # what it is measuring. Latency statistics are computed here for a duller reason
      # -- every sample is in by now.
      def run_post_load_analysis(endpoints)
        # RUN-LEVEL FIRST, because the pattern that explains a report full of
        # `inconclusive` is only visible across endpoints. One 403 is an admin
        # endpoint; every endpoint returning 403 is a misconfigured token, and the
        # per-endpoint reason is chosen from that conclusion below.
        @traffic = traffic_diagnosis.diagnose(traffic_observations(endpoints.map(&:to_s)))
        @traffic.each { |diagnosis| @stdout.puts "loadwright: #{diagnosis.message}" }

        endpoints.each do |endpoint|
          key = endpoint.to_s
          next if @cells.none? { |cell| cell.endpoint_key == key }

          @latency[key] = latency_summaries(key)
          @time_breakdowns[key] = time_breakdown_for(key)
          @explain[key] = explain_analyzer.analyze(
            explain_analyzer.candidates_from(@slow_queries.fetch(key, {}).values, endpoint_key: key),
            query_data: query_data_for?(key)
          )
        end
      ensure
        explain_analyzer.close!
      end

      # One summary per CELL, never one per endpoint. A cell holds one scale factor,
      # one page size and one concurrency level, so its latencies are draws from a
      # single distribution; pooling concurrency 1 with concurrency 20 would produce a
      # median describing neither, and the resulting spread would read as noise.
      # One entry per endpoint that was actually exercised. Statuses are pooled across
      # its cells: a 429 anywhere is a 429, and "every response was 401/403" is a
      # property of the endpoint rather than of one cell.
      def traffic_observations(endpoint_keys)
        endpoint_keys.to_h do |key|
          cells = @cells.select { |cell| cell.endpoint_key == key && !cell.skipped? }

          [key, {
            statuses: cells.flat_map { |cell| Array(cell.statuses) }.compact,
            rate_limit_headers: cells.each_with_object({}) { |cell, out| out.merge!(cell.rate_limit_headers || {}) }
          }]
        end.reject { |_, observation| observation[:statuses].empty? }
      end

      def latency_summaries(endpoint_key)
        @cells.select { |cell| cell.endpoint_key == endpoint_key && !cell.skipped? }
              .map { |cell| statistics.summarize(cell.latencies, label: cell_label(cell)) }
      end

      # Clears the application cache before an endpoint's FIRST cell, and only then.
      # Returns whether it was actually cleared -- a shared store is left alone, and the
      # result then reports a first-request figure rather than claiming a cold one.
      def prepare_cold_pass(endpoint)
        return false if @cold_measured[endpoint.to_s]

        cold_warm.prepare!
      end

      def record_cold_warm(endpoint, cell, cache_cleared)
        key = endpoint.to_s
        return if @cold_measured[key]
        return if cell.cold_latencies.compact.empty?

        @cold_measured[key] = true
        @cold_warm[key] = cold_warm.compare(cell.cold_latencies, cell.latencies, cache_cleared: cache_cleared)
      end

      def record_rate_limit_headers(cell, response)
        Analysis::TrafficDiagnosis::RATE_LIMIT_HEADERS.each do |name|
          value = response.header(name)
          cell.rate_limit_headers[name] = value if value
        end
      end

      # WHERE THE TIME ACTUALLY WENT, per endpoint. This is what stops the report
      # blaming the database for a serialisation problem: an endpoint at 340ms with 3
      # queries has no query-count finding at all, and if 280ms of it is view time the
      # advice is "your serialiser is the problem" rather than anything about SQL.
      #
      # Medians across the endpoint's cells, so one slow outlier does not redraw the
      # picture.
      def time_breakdown_for(endpoint_key)
        cells = @cells.select { |cell| cell.endpoint_key == endpoint_key && !cell.skipped? }
        return nil if cells.empty?

        breakdown = Analysis::TimeBreakdown.from_totals(
          total_ms: median_across(cells, :latencies),
          db_ms: median_across(cells, :db_runtimes),
          view_ms: median_across(cells, :view_runtimes),
          gc_ms: median_across(cells, :gc_times)
        )
        breakdown&.to_h
      end

      def median_across(cells, field)
        values = cells.flat_map { |cell| Array(cell.public_send(field)).compact }.sort
        return nil if values.empty?

        values[(values.length - 1) / 2].to_f
      end

      def query_data_for?(endpoint_key)
        @cells.any? { |cell| cell.endpoint_key == endpoint_key && cell.query_counts.compact.any? }
      end

      def cell_label(cell)
        "#{cell.sweep} scale=#{cell.scale_factor} page=#{cell.page_size || 'default'} " \
          "concurrency=#{cell.actual_concurrency || cell.requested_concurrency}"
      end

      def outcome_for(endpoint)
        key = endpoint.to_s
        cells = @cells.select { |cell| cell.endpoint_key == key }
        verdicts = @verdicts.fetch(key, [])

        return skipped_outcome(endpoint) if cells.empty?

        # Recorded for EVERY exercised endpoint, whatever the outcome -- including the
        # inconclusive ones below, which is where a reader most wants to know whether
        # the schema was consulted.
        @schema_validation[key] = schema_validation_for(verdicts, endpoint)

        # The validity gate comes first, always. No performance verdict is attached to
        # a response that did not prove it did the work.
        invalid = verdicts.find { |verdict| !verdict.valid? }
        if invalid
          # A more specific reason when the run-level pattern supports one.
          # `:unsuccessful_status` only says an error path was measured;
          # `:auth_failed` and `:rate_limited` name the fix.
          # A page size WE chose is our doing, not the endpoint's, and it gets its own
          # reason before the generic one.
          rejected = page_size_rejection(cells)
          return inconclusive(endpoint, :page_size_rejected, rejected) if rejected

          diagnosed = traffic_reason_for(key)
          return inconclusive(endpoint, diagnosed || invalid.reason,
                              "#{invalid.detail}#{replayed_identifier_note(key, cells)}" \
                              "#{pre_data_layer_note(cells)}#{app_exception_note(cells)}" \
                              "#{zero_row_query_note(cells)}",
                              findings: retained_findings_for(endpoint, cells, invalid.reason),
                              # COVERAGE HAS TO MATCH WHAT WAS PRINTED. Without it the
                              # outcome carried Coverage.none, so the line read "not
                              # checked: N+1, ... latency percentiles" directly below a
                              # printed N+1 and directly above six cells of populated
                              # percentiles. The detectors ran; only the verdict is
                              # withheld.
                              coverage: retained_coverage_for(endpoint, key, cells, invalid.reason))
        end

        shapes = cells.map(&:shape)
        unless validator.consistent_shape?(shapes)
          return inconclusive(endpoint, :inconsistent_shape, validator.shape_inconsistency_detail(shapes))
        end

        return inconclusive(endpoint, :quarantined, quarantine_detail(key)) if @guard&.quarantined?(key)

        findings = findings_for(endpoint, cells)
        context = duplicate_context_for(cells)
        @correlations[key] = correlator.to_h(observations_for(cells),
                                             context.transform_values { |entry| entry[:occurrences] },
                                             context)

        # The state comes from finding-class COVERAGE, not from how many signals
        # happened to produce a number. EndpointOutcome.derive owns the precedence so
        # reporting renders a state rather than recomputing one.
        EndpointOutcome.derive(
          endpoint: endpoint,
          findings: findings,
          coverage: coverage_for(key, cells),
          capability_epoch: cells.last.capability_epoch
        )
      end

      # Coverage is computed per endpoint from the detectors that actually ran, and is
      # attached to EVERY outcome regardless of state — a reader can then see that an
      # otherwise-clean endpoint was checked with one N+1 detector instead of two,
      # without `inconclusive` having to be overloaded to signal it.
      def coverage_for(endpoint_key, cells)
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
            payload_growth: payload_growth_state(seed_scale_cells),
            explain: @explain.fetch(endpoint_key, nil)&.detector_state ||
                     [:unavailable, "the EXPLAIN phase did not run for this endpoint"],
            percentiles: statistics.detector_state(@latency.fetch(endpoint_key, []))
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

      # Deliberately separate from `table_in`, which feeds the over-fetch signal and
      # must stay about tables that were READ. An INSERT is not a read.
      def inserted_table_in(fingerprint)
        fingerprint.to_s[/\AINSERT\s+INTO\s+[`"']?([A-Za-z0-9_]+)/i, 1]
      end

      # The slowest example of each distinct query shape, kept for the EXPLAIN phase.
      #
      # Keyed by fingerprint rather than appended, for two reasons. It bounds memory by
      # the number of query SHAPES instead of by requests issued, and explaining the
      # same shape once per request would produce N copies of one finding.
      def remember_slow_query(endpoint_key, query)
        return if query[:sql].nil?

        shapes = (@slow_queries[endpoint_key] ||= {})
        existing = shapes[query[:fingerprint]]
        shapes[query[:fingerprint]] = query if existing.nil? ||
                                              query[:duration_ms].to_f > existing[:duration_ms].to_f
      end

      # WAS THIS RESPONSE CHECKED AGAINST ITS DECLARED SCHEMA, AND IF NOT, WHY NOT.
      #
      # Derived from what the validator actually did rather than from configuration,
      # because the two answer different questions. `require_schema_valid_response`
      # says whether a violation invalidates the response; it does not say whether
      # there was a schema to check against. An endpoint whose operation declares no
      # response schema is not validated no matter how the setting is left, and
      # reporting the setting would tell a reader the check ran when it did not.
      #
      # Verdict#schema_errors is the ground truth and is deliberately tri-state:
      # nil (no schema for this operation), [] (checked, clean), non-empty (checked,
      # violations). The same distinction Measurement makes, for the same reason.
      def schema_validation_for(verdicts, endpoint)
        # OURS, AND SAID SO. A schema we could not load is not a response that failed,
        # and reporting the first as the second told twenty endpoints their responses
        # were invalid on the strength of a check that never ran. It is reported as a
        # tool fault, the endpoint is judged on everything else, and no finding is
        # discarded for it.
        resolution = verdicts.filter_map(&:schema_resolution_error).first
        return { state: :unresolvable, note: format(UNRESOLVABLE_NOTE, error: resolution) } if resolution

        errors = verdicts.map(&:schema_errors)
        return unmatched_or_undeclared(endpoint) if errors.all?(&:nil?)

        violations = errors.compact.reject(&:empty?)
        return { state: :validated, note: "validated against the declared response schema" } if violations.empty?

        # No error text here. The violations already reach the report through the
        # endpoint's inconclusive detail, and duplicating raw schema messages into a
        # second field puts response-derived strings through the redactor twice for no
        # extra signal.
        { state: :violations, checked: errors.compact.length, note: violation_note }
      end

      def unmatched_or_undeclared(endpoint)
        return { state: :no_schema, note: NO_SCHEMA_NOTE } if endpoint.from?(:openapi)

        { state: :no_document_match,
          note: format(NO_DOCUMENT_MATCH_NOTE, sources: endpoint.sources.join(", ")) }
      end

      def violation_note
        return "the response did not match its declared schema" if @config.require_schema_valid_response

        "the response did not match its declared schema, and require_schema_valid_response is false, " \
          "so this did not affect the endpoint's verdict"
      end

      def findings_for(endpoint, cells)
        # The two sweeps answer different questions, so their observations are fed to
        # the correlator separately — the whole point of holding one axis fixed in each.
        page_size_cells = cells.select { |cell| cell.sweep == :page_size && !cell.skipped? }
        seed_scale_cells = cells.select { |cell| cell.sweep == :seed_scale && !cell.skipped? }

        # THE WORST SINGLE REQUEST, ACROSS CELLS -- the same rule absorb applies within
        # one cell, and it has to hold here too. This concatenated, so a finding said
        # "the same query ran 12 times in a single request" about an endpoint whose own
        # cells table reported 8 queries per request in total. A request issuing 8
        # queries cannot issue one of them 12 times; the report contradicted itself on
        # the same page.
        #
        # Worse than wrong: the number scaled with scale_factors x page_size_sweep, so
        # it was a property of the reader's CONFIGURATION, not of their endpoint.
        # Following the advice to raise scale_factors tripled every N+1 severity in the
        # report with no change to the app, corrupted run-over-run comparison, and made
        # a fixed repeat look like one that scales -- arguing against the very
        # classification the fixed/scaling split exists to make.
        context = duplicate_context_for(cells)

        findings = correlator.findings(
          observations: observations_for(page_size_cells.empty? ? seed_scale_cells : page_size_cells),
          duplicates: context.transform_values { |entry| entry[:occurrences] },
          duplicate_context: context,
          # EVERY cell, for the fixed/scaling question only. The slope needs one sweep
          # at a time; the repeat classifier needs whichever axis actually moved, and
          # on an API of single-record endpoints the seeded scale is the only one that
          # ever does.
          scaling_observations: observations_for(page_size_cells + seed_scale_cells)
        )
        findings.concat(correlator.findings(observations: observations_for(seed_scale_cells)).select do |finding|
          %i[missing_pagination oversized_payload].include?(finding.kind)
        end)

        findings.concat(Array(@guard&.findings).select { |finding| finding.endpoint_key == endpoint.to_s })
        findings.concat(latency_findings(endpoint.to_s))
        findings.concat(Array(@explain[endpoint.to_s]&.findings))
        findings.concat(job_volume_findings(endpoint.to_s, cells))
        # NOT Array(...): Struct#to_a explodes a Finding into its four members, and
        # `[:cold_cache_dependency, :medium, "...", {}]` then flows on as four findings,
        # none of which respond to #kind.
        findings.concat([cold_warm.finding_for(endpoint.to_s, @cold_warm[endpoint.to_s])].compact)

        annotate(findings)
      end

      # A REQUEST ENQUEUING 200 JOBS IS A FINDING IN ITS OWN RIGHT
      # (performance-signals.md Part 1), and containment is what makes it visible: the
      # :test adapter records rather than performs, which turns suppression into a
      # measurement. Reported per request, not per run -- the run total rises with
      # nothing but the number of requests issued.
      def job_volume_findings(endpoint_key, cells)
        counts = cells.reject(&:skipped?).flat_map { |cell| Array(cell.jobs_enqueued).compact }
        return [] if counts.empty?

        worst = counts.max
        return [] if worst <= @config.jobs_enqueued_warning_threshold

        [Analysis::ResponseCorrelator::Finding.new(
          kind: :job_fan_out,
          confidence: :high,
          detail: "one request enqueued #{worst} background job(s), against a threshold of " \
                  "#{@config.jobs_enqueued_warning_threshold}. Containment recorded them instead of " \
                  "performing them, so this run did not pay their cost -- production would.",
          evidence: { endpoint: endpoint_key, max_jobs_per_request: worst,
                      threshold: @config.jobs_enqueued_warning_threshold }
        )]
      end

      # The WORST cell that had enough samples to say anything, not the average across
      # cells. An endpoint that meets its budget at concurrency 1 and blows it at 20 has
      # a latency problem, and averaging the two would hide exactly the case worth
      # reporting.
      def latency_findings(endpoint_key)
        budget = statistics.budget_for(endpoint_key)
        return [] if budget.nil?

        checks = Array(@latency[endpoint_key]).filter_map { |summary| statistics.budget_check(summary, budget) }
        worst = checks.select(&:exceeded?).max_by(&:observed_ms)
        return [] if worst.nil?

        [Analysis::ResponseCorrelator::Finding.new(
          kind: :latency_budget_exceeded,
          confidence: :medium,
          detail: "#{worst.checked_at} latency was #{worst.observed_ms.round(1)}ms against a " \
                  "#{worst.budget_ms}ms budget#{worst.caveat ? ". #{worst.caveat}" : ''}",
          evidence: { endpoint: endpoint_key, budget_ms: worst.budget_ms, checked_at: worst.checked_at,
                      observed_ms: worst.observed_ms.round(3) }
        )]
      end

      def annotate(findings)
        findings.each do |finding|
          next unless finding.respond_to?(:detail) && finding.respond_to?(:evidence)

          # The resolver first: for GraphQL it is the thing you go and fix, and a file
          # and line inside a Type class is much less use than the field's own name.
          resolver = finding.evidence.is_a?(Hash) && finding.evidence[:resolver]
          finding.detail = "#{finding.detail} — resolved by #{resolver}" if resolver

          sentence = attribution.annotate(finding)
          finding.detail = "#{finding.detail} — #{sentence}" if sentence
        end
      end

      # The worst single request across cells, same rule the finding itself uses.
      # THE WORST SINGLE REQUEST, AND WHICH CELL IT CAME FROM.
      #
      # The merge takes the max per fingerprint rather than concatenating, because a
      # repeat count is a property of ONE request. Carrying the winning cell alongside
      # it is what makes the number self-checkable: "ran 12 times in a single request"
      # sat next to a cell table reporting 8 queries per request for five releases, and
      # nobody could see the contradiction because the two numbers were never printed
      # together. The invariant (a repeat cannot exceed that request's query count) is
      # specced; this is the same invariant made visible to a reader.
      def duplicate_context_for(cells)
        cells.each_with_object({}) do |cell, out|
          Array(cell.duplicates).each do |fingerprint, occurrences|
            existing = out[fingerprint]
            next if existing && existing[:occurrences].length >= occurrences.length

            out[fingerprint] = { occurrences: occurrences, cell: cell_label(cell),
                                 queries: cell.median_queries }
          end
        end
      end

      def duplicates_for(cells)
        duplicate_context_for(cells).transform_values { |entry| entry[:occurrences] }
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

      # "THIS ENDPOINT 404s" AND "THIS ENDPOINT 404s WITH PARAMETERS WE REPLAYED FROM A
      # SPEC" ARE DIFFERENT SENTENCES. The first is about the app; the second is about
      # us, and pointing a reader at their own code for it wastes their time.
      # ANY unsuccessful status, not only 404. A replayed placeholder can just as easily
      # produce a 400 or a 422, and the reader needs the same sentence for those: this
      # may be ours rather than the endpoint's.
      def replayed_identifier_note(key, cells)
        names = Array(@replayed_identifiers[key])
        return "" if names.empty?

        statuses = cells.flat_map { |cell| Array(cell.statuses) }.compact
        return "" if statuses.empty? || statuses.all? { |status| (200..299).cover?(status) }

        " This request carried #{names.join(', ')} replayed verbatim from a recording, because " \
          "nothing seeded could resolve #{names.length == 1 ? 'it' : 'them'} -- so this status may be " \
          "ours rather than the endpoint's. Seed the resource, or name the value in path_param_overrides."
      end

      # THE SWEEP DROVE IT OUT OF RANGE.
      #
      # The first collection-shaped endpoint ever measured answered 200 at its own
      # default and at page size 25, and 400 at page sizes 5 and 100 -- same endpoint,
      # same resolved id, a different verdict per cell. It accepts a set of page sizes
      # and the sweep asked for values outside it.
      #
      # Reporting that as an ordinary error status sends the reader to look at their
      # app for something we did. It is the same species as the replayed-identifier
      # note: when the tool supplied the value that failed, say so.
      #
      # Still inconclusive, deliberately. Loosening the validity gate for a
      # partly-successful endpoint is exactly how a 404 ended up in the healthy list;
      # what changes here is the REASON and the advice, not the verdict.
      def page_size_rejection(cells)
        page_cells = cells.select { |cell| cell.sweep == :page_size && Array(cell.statuses).any? }
        seed_cells = cells.select { |cell| cell.sweep == :seed_scale && Array(cell.statuses).any? }
        return nil if page_cells.empty? || seed_cells.empty?

        # Every seed-scale cell fine, so nothing about the endpoint itself is failing.
        return nil unless seed_cells.all? { |cell| all_successful?(cell) }

        rejected = page_cells.reject { |cell| all_successful?(cell) }
        accepted = page_cells.select { |cell| all_successful?(cell) }
        return nil if rejected.empty?

        statuses = rejected.flat_map { |cell| Array(cell.statuses) }.reject { |s| (200..299).cover?(s) }.uniq
        worked = (accepted.map(&:page_size) + [nil]).compact.uniq

        "answered #{statuses.join('/')} at page size #{rejected.map(&:page_size).join(', ')}, and " \
          "answered successfully at its own default#{worked.empty? ? '' : " and at #{worked.join(', ')}"}. " \
          "The page-size sweep chose those values; this endpoint accepts a different set, so it was " \
          "driven out of range rather than failing. Set page_size_sweep to values it accepts. Until then " \
          "the N+1-behind-pagination check could not run on the rejected pages, which is what the " \
          "page-size sweep exists for."
      end

      def all_successful?(cell)
        Array(cell.statuses).compact.all? { |status| (200..299).cover?(status) }
      end

      # Kept by CLASS, not appended per request. A hundred requests failing the same
      # way is one fact, and a list of a hundred identical entries is not more
      # information than one.
      def note_app_exception(cell, response)
        details = response.respond_to?(:app_exception) ? response.app_exception : nil
        return if details.nil?

        cell.app_exceptions ||= {}
        cell.app_exceptions[details[:class]] ||= details
      end

      # WHY THIS ENDPOINT CANNOT BE A SEEDING PROBLEM, SAID MECHANICALLY.
      #
      # A request that issued zero queries never reached the data layer, so no factory,
      # trait, `param:` or scale factor can change its outcome. The number that proves
      # it has been printed in the cell table since the first run -- and an integration
      # still spent four rounds recommending a factory fix for fifteen endpoints whose
      # own rows said zero queries, because nothing in the report ever objected.
      #
      # This is the cheapest kind of check the tool can do: it uses a number already
      # measured, and it rules out a whole class of wrong remedy.
      def pre_data_layer_note(cells)
        measured = cells.reject(&:skipped?)
        statuses = measured.flat_map { |cell| Array(cell.statuses) }.compact
        return "" if statuses.empty? || statuses.any? { |status| status < 500 }

        queries = measured.flat_map { |cell| Array(cell.query_counts) }.compact
        return "" if queries.empty? || queries.any?(&:positive?)

        " Every request issued ZERO queries, so it failed before reaching the data layer: " \
          "no factory, trait or scale factor can change this endpoint's outcome, and seeding is not " \
          "the remedy."
      end

      # ON ITS OWN, not folded into the zero-query note. It was only ever printed as part
      # of that sentence, so an endpoint that DID reach the database and then raised --
      # which is most 500s, and every one that renders a framework error page -- named
      # nothing at all. A quarantined endpoint is precisely the one whose cause nobody
      # has, which makes it the place a named exception is worth most.
      def app_exception_note(cells)
        exceptions = cells.reject(&:skipped?)
                          .flat_map { |cell| Hash(cell.app_exceptions).values }.uniq { |e| e[:class] }
        return "" if exceptions.empty?

        described = exceptions.first(3).map do |exception|
          # THE CONTAINMENT ATTRIBUTION IS THE HALF ONLY WE CAN MAKE. When our own
          # outbound-HTTP block is what broke the request, the app looks broken and is
          # not, and the user cannot tell -- the block is ours and invisible to them.
          [exception[:class], exception[:frame], exception[:containment]].compact.join(" @ ")
        end

        " Raised: #{described.join('; ')}."
      end

      # WHAT IS AND IS NOT AFFECTED, because the obvious reading of this is wrong and
      # the first version of this warning got it backwards.
      #
      # Query and repeat counts are LOGICAL: the tracker records every query the code
      # issued, cache hit or not, so the N+1 threshold is applied to how many times the
      # code ASKED. Nothing is undercounted and no finding is missed. What a live cache
      # does change is LATENCY -- those requests were served warm -- and the executed
      # figure reported alongside each repeat count, which is lower than the logical
      # one by exactly the hits.
      #
      # Said out loud because the setting promises the cache is off and it is not:
      # Rails' own QueryCache middleware enables it per request, after our setup-time
      # disable, and nothing until now noticed.
      # A SEEDED RESOURCE NOBODY ASKED FOR. The factory ran, the rows exist, and every
      # request went out carrying something else -- with no warning, because a lookup
      # miss looks exactly like having no factory_map entry. Naming both sides (what was
      # seeded, what endpoints actually asked for) turns a cross-round investigation
      # into one line.
      def resolver_warnings
        [@resolver.respond_to?(:unconsumed_warning) ? @resolver.unconsumed_warning : nil].compact
      end

      # WHY THERE WAS NOTHING TO REPLAY, when the answer is that every recording of this
      # template was a spec asserting a rejection. Without this the endpoint reads as an
      # ordinary resolution failure and the reader goes looking for a factory -- when
      # what actually happened is that their suite never exercised it successfully.
      def rejection_only_note(endpoint)
        return "" unless endpoint.respond_to?(:recorded_only_as_rejection?) && endpoint.recorded_only_as_rejection?

        " Every one of the #{endpoint.recorded_attempts} recording(s) of this template was a request " \
          "your specs expected to be REJECTED, so no usable identifier was captured from any of them " \
          "and none was replayed. The route is real; nothing here says the endpoint is broken. Give it " \
          "a factory_map entry or a path_param_overrides value and it becomes measurable."
      end

      def query_cache_warnings
        return [] unless @query_cache_observed && @config.disable_query_cache_during_run

        ["disable_query_cache_during_run is true and query-cache hits were still recorded: Rails' own " \
         "QueryCache middleware enables the cache per request, after our disable, so the setting did not " \
         "take effect. Query and repeat counts are UNAFFECTED -- they count every query the code issued, " \
         "cache hit or not, so the N+1 threshold still applies to how many times your code asked. What is " \
         "affected is latency, which is a warm-cache measurement here, and the `executed` figure printed " \
         "beside each repeat count, which is lower than the total by exactly the number of hits."]
      end

      def select?(fingerprint) = fingerprint.to_s.match?(/\A\s*SELECT\b/i)

      # WHICH SCOPE EXCLUDED THE DATA, not merely that one did.
      #
      # "The seeded records did not match this endpoint's scope" is true and leaves the
      # reader to find the scope themselves. The filter columns of the query that
      # returned nothing are the actionable half, and they name the factory trait or
      # attribute that would fix it.
      def zero_row_query_note(cells)
        fingerprints = cells.reject(&:skipped?).flat_map { |cell| Array(cell.zero_row_queries) }.uniq
        return "" if fingerprints.empty?

        described = fingerprints.first(2).map do |fingerprint|
          table = table_in(fingerprint) || "a table"
          columns = filter_columns(fingerprint)
          columns.empty? ? table : "#{table} filtered on #{columns.join(', ')}"
        end

        " No rows came back from: #{described.join('; ')}. That is the scope that excluded the seeded " \
          "data -- a factory trait setting those columns is usually the fix."
      end

      # SQL KEYWORDS AND TABLE NAMES ARE NOT COLUMNS, and the first version of this
      # reported both. `IN` with no word boundary matched inside `DISTINCT` and `JOIN`,
      # so it emitted `DIST` and `JO` as column names and truncated real identifiers
      # mid-word -- one of them to a single character matching three different columns
      # on its own table. Roughly two thirds of the attributions carried at least one
      # token that was not a column. Naming fewer columns confidently beats naming four
      # fragments.
      #
      # Three changes, each removing a class of wrong answer:
      #   * only the WHERE clause is read, so a SELECT list and a JOIN's ON keys --
      #     which are join structure rather than the filter that excluded the rows --
      #     cannot leak in
      #   * word operators are anchored with \b, which is what produced DIST and JO
      #   * an optional table qualifier is consumed, so `"widgets"."status"` yields the
      #     column and not the table
      FILTER_KEYWORDS = %w[AND OR NOT WHERE SELECT FROM JOIN INNER LEFT RIGHT OUTER ON LIMIT OFFSET
                           ORDER GROUP BY HAVING AS DISTINCT NULL TRUE FALSE CASE WHEN THEN ELSE END
                           EXISTS ALL ANY].freeze

      FILTER_OPERATOR = /\s*(?:<=|>=|<>|!=|=|<|>|\bIN\b|\bIS\b|\bLIKE\b|\bILIKE\b|\bBETWEEN\b)/i

      FILTER_COLUMN =
        /(?:[`"']?[A-Za-z_][A-Za-z0-9_]*[`"']?\.)?[`"']?([A-Za-z_][A-Za-z0-9_]*)[`"']?#{FILTER_OPERATOR}/o

      def filter_columns(fingerprint)
        where = fingerprint.to_s[/\bWHERE\b(.*)/im, 1]
        return [] if where.nil?

        where = where.sub(/\b(?:ORDER|GROUP|LIMIT|OFFSET|HAVING)\b.*/im, "")
        where.scan(FILTER_COLUMN)
             .flatten
             .reject { |name| FILTER_KEYWORDS.include?(name.upcase) }
             .uniq
             .first(4)
      end

      def failure_notes_for(endpoint)
        cells = @cells.select { |cell| cell.endpoint_key == endpoint.to_s }

        "#{pre_data_layer_note(cells)}#{app_exception_note(cells)}"
      end

      def quarantine_detail(key)
        "#{contention_quarantine_detail(key)}#{failure_notes_for_key(key)}"
      end

      def failure_notes_for_key(key)
        cells = @cells.select { |cell| cell.endpoint_key == key }

        "#{pre_data_layer_note(cells)}#{app_exception_note(cells)}"
      end

      def contention_quarantine_detail(key)
        events = Array(@guard&.events).select { |event| event.endpoint_key == key }
        blocker = events.map(&:blocker).uniq.join(", ")

        "abandoned after the backoff ladder; #{events.length} contention event(s), blocker: #{blocker}"
      end

      def traffic_reason_for(endpoint_key)
        observation = traffic_observations_cache[endpoint_key]
        return nil if observation.nil?

        traffic_diagnosis.reason_for(endpoint_key, observation, Array(@traffic))
      end

      def traffic_observations_cache
        @traffic_observations_cache ||= traffic_observations(@cells.map(&:endpoint_key).uniq)
      end

      def already_decided?(endpoint) = @outcomes.any? { |outcome| outcome.endpoint == endpoint }

      def skipped_outcome(endpoint)
        reason = @breaker.tripped? ? :circuit_breaker : :run_aborted

        EndpointOutcome.inconclusive(endpoint: endpoint, reason: reason)
      end

      def inconclusive(endpoint, reason, detail, findings: [], coverage: nil)
        EndpointOutcome.inconclusive(endpoint: endpoint, reason: reason, detail: detail,
                                     findings: findings, coverage: coverage,
                                     capability_epoch: @context.capability_epoch)
      end

      def retained_coverage_for(_endpoint, key, cells, reason)
        return nil unless RETAINS_FINDINGS.include?(reason)

        coverage_for(key, cells)
      rescue StandardError
        nil
      end

      # THE ONE REASON WHOSE RESPONSES DID THE WORK.
      #
      # A schema violation says the payload does not match its documentation. Every
      # other invalid reason says the response did not prove it did the work at all --
      # an error status, an empty collection where records were seeded, a page size the
      # endpoint rejected, a shape that changed between cells. Findings measured on
      # those describe an error path and are correctly discarded; that is the round-5
      # healthy-404 rule and it is not being loosened.
      #
      # Findings measured on a 200 that merely under-documents itself are real, and
      # dropping them cost one integration two rounds of a high-confidence N+1 the tool
      # had reported correctly in the eight rounds before.
      RETAINS_FINDINGS = %i[schema_invalid].freeze

      def retained_findings_for(endpoint, cells, reason)
        return [] unless RETAINS_FINDINGS.include?(reason)

        findings_for(endpoint, cells)
      rescue StandardError
        # A finding we could not assemble is not worth failing the outcome over: the
        # endpoint is already inconclusive and the detail already says why.
        []
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
        warn_about_unmeasurable_page_size_sweep

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

      def statistics = @statistics ||= Analysis::Statistics.new(config: @config)

      def cold_warm = @cold_warm_analyzer ||= Analysis::ColdWarm.new(config: @config)

      def traffic_diagnosis = @traffic_diagnosis ||= Analysis::TrafficDiagnosis.new(config: @config)

      def containment_disclosure
        @containment_disclosure ||= Analysis::ContainmentDisclosure.from(@containment)
      end

      def pool_sizing
        @pool_sizing ||= Analysis::PoolSizingCheck.new(
          config: @config, capability: @context.capability_profile, pool_tracker: @pool_tracker
        ).check
      end

      def explain_analyzer = @explain_analyzer ||= Analysis::ExplainAnalyzer.new(config: @config, stdout: @stdout)

      def correlator
        @correlator ||= Analysis::ResponseCorrelator.new(config: @config, capability: @context.capability_profile)
      end

      def attribution = @attribution ||= Analysis::SerializerAttribution.new(config: @config)

      public

      def reset!
        @cells = []
        @outcomes = []
        @verdicts = {}
        @schema_validation = {}
        @correlations = {}
        # Slowest exemplar per (endpoint, fingerprint). Bounded by the number of
        # distinct query shapes rather than by request count, so a long run does not
        # accumulate one entry per request.
        @slow_queries = {}
        @explain = {}
        @latency = {}
        @cold_warm = {}
        @time_breakdowns = {}
        # Which endpoints have already had their cold pass measured. The cold figure is
        # only meaningful for the FIRST cell an endpoint is exercised in -- by the
        # second, the application cache is warm and "cold" would be a lie.
        @cold_measured = {}
        @traffic = []
        @completed = false
        self
      end
    end
  end
end

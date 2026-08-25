# frozen_string_literal: true

require "loadwright/cli/app_loader"
require "loadwright/discovery/pipeline"

module Loadwright
  class CLI
    # `loadwright run`. Everything between "the user typed a command" and "there is a
    # report on disk".
    #
    # This lives outside cli.rb because it is not argument parsing -- it is the only
    # place in the gem where the whole pipeline is assembled in the order the safety
    # model requires, and that order is the substance of it:
    #
    #   boot -> guard -> containment -> discovery -> context -> estimate -> run
    #
    # The first three are not negotiable and not reorderable. The guard cannot detect
    # an environment before the app defines one. Containment goes in before ANY
    # request can be issued, not before the first mutating one, because discovery
    # itself can execute app code. And nothing may build a transport until the guard
    # has returned a Decision (CLAUDE.md section 2).
    #
    # Teardown is symmetric and runs in `ensure`: an exception between context.start!
    # and the report must still stop the server and delete the seeded rows.
    class RunCommand
      # Distinct so a script can tell "the tool refused" from "the tool ran and your
      # API has problems". Conflating them is how a safety refusal gets read as a
      # clean bill of health.
      OK = 0
      FINDINGS = 1
      REFUSED = 3
      INTERRUPTED = 130

      # How long the signal watcher gives the main thread to finish its own report
      # before assuming it is wedged and writing one itself. Generous, because the
      # main thread is finishing an analysis pass, not starting one -- and the cost of
      # being wrong in the impatient direction is two reports and a data race, while
      # the cost of being wrong in the patient direction is a few seconds before a
      # Ctrl-C that was always going to work anyway.
      FINISH_GRACE_SECONDS = 20

      def initialize(options:, stdout: $stdout, stderr: $stderr, stdin: $stdin,
                     loader: nil, guard: nil, lifecycle: nil)
        @options = options
        @stdout = stdout
        @stderr = stderr
        @stdin = stdin
        @loader = loader
        @guard = guard
        @lifecycle = lifecycle
        @finish_lock = Mutex.new
        @finished = ConditionVariable.new
        @main_thread_done = false
      end

      def call
        boot!
        apply_overrides!
        config.validate!

        decision = approve!
        install_containment!

        discovery = discover!
        return no_endpoints(discovery) if discovery.endpoints.empty?

        execute_run(discovery, decision)
      rescue Loadwright::Error => e
        # EVERY designed refusal, not just the safety ones. A refusal is an outcome,
        # not a crash: it prints as a message and an exit code, never as a backtrace,
        # because a stack trace here reads as a bug in the tool and sends the user to
        # the wrong codebase entirely.
        #
        # Deliberately the whole Loadwright::Error family. SafetyError alone left
        # DiscoveryError (a named OpenAPI document that is not there), SeedingError
        # (auth_token_provider raised), and ServerError (the app would not boot under
        # :http) escaping as backtraces -- all three of them messages we wrote
        # precisely so the user would not need one.
        #
        # RunAborted and Interrupted are not expected here: the runner catches both
        # and returns a partial result. One arriving before the runner started is
        # still possible, which is what the interrupted check below is for.
        #
        # A non-Loadwright error is NOT caught. That is a bug in the gem, and a
        # backtrace is the correct output for it.
        @stderr.puts "loadwright: #{e.message}"
        lifecycle.interrupted? ? INTERRUPTED : REFUSED
      ensure
        # Before teardown, and on EVERY path: a refusal or a crash must not leave the
        # signal watcher waiting out its full grace period for a main thread that has
        # already given up.
        release_main_thread!
        teardown!
      end

      private

      def config = @config ||= Loadwright.configuration

      def lifecycle = @lifecycle ||= Lifecycle.new(stderr: @stderr)

      def dry_run? = !@options[:execute]

      # ------------------------------------------------------------------- the phases

      def boot!
        (@loader || AppLoader.new(stdout: @stdout)).load!
      end

      # AFTER the initializer has run, so a flag beats the file rather than the file
      # silently beating the flag.
      def apply_overrides!
        return if @options[:mode].nil?

        config.execution_mode = @options[:mode]
      end

      def approve!
        guard = @guard || Safety::EnvironmentGuard.new(
          config: config, confirmation: Safety::Confirmation.new(stdin: @stdin, stdout: @stdout),
          stdout: @stdout
        )
        guard.approve!(risk_acknowledged: @options[:risk_acknowledged], execute: @options[:execute])
      end

      # Installed even for a dry run. A dry run issues no requests, so containment is
      # not protecting anything yet -- but "your mail containment cannot be enforced"
      # is exactly the kind of thing the dry run exists to tell you BEFORE you type
      # --execute, and discovering it only on the real run defeats the point of having
      # a rehearsal at all.
      #
      # IT MUST NOT ABORT ONE, THOUGH. A dry run sends nothing: no mail, no job, no
      # outbound call. Refusing it guards against something that cannot happen, and
      # costs the user the endpoint list -- the whole output of the command, and the
      # first thing the tool tells them to look at.
      #
      # This is not hypothetical. `block_outbound_http` is on by default and needs
      # webmock, webmock is not a runtime dependency, and
      # `abort_if_containment_unavailable` is also on by default. So a new user
      # following the README hit a refusal on their very first command, before seeing
      # a single endpoint. Found by installing the built gem into a fresh Rails app.
      def install_containment!
        @containment = SideEffects::Containment.new(config: config, lifecycle: lifecycle, stdout: @stdout)
        @containment.install!
      rescue ContainmentError => e
        raise unless dry_run?

        @stdout.puts "loadwright: #{e.message}"
        @stdout.puts "loadwright: continuing anyway — a dry run issues no requests, so nothing can " \
                     "escape. Fix the above before you use --execute, which will refuse."
      end

      def discover!
        result = Discovery::Pipeline.new(config: config, stdout: @stdout).discover(only: @options[:only])
        result.warnings.each { |warning| @stdout.puts "loadwright: #{warning}" }
        @stdout.puts discovery_line(result)
        result
      end

      # Deliberately separates DISCOVERED from TO EXERCISE. They differ whenever
      # anything was excluded or is unexercisable, and an earlier version printed
      # "discovered 8 endpoint(s) (9 from route)" -- two different numbers for two
      # different things, presented as though one explained the other.
      def discovery_line(result)
        sources = result.by_source.reject { |_, count| count.zero? }
                        .map { |name, count| "#{name} #{count}" }.join(", ")
        parts = ["loadwright: #{result.endpoints.length} endpoint(s) to exercise"]
        parts << "#{result.skipped.length} discovered but not exercisable" if result.skipped.any?
        parts << "sources: #{sources}" unless sources.empty?
        parts.join(" — ")
      end

      # -------------------------------------------------------------------- the run

      def execute_run(discovery, decision)
        @context = Execution::ExecutionContext.build(
          config: config, dry_run: dry_run?, lifecycle: lifecycle, guard: resource_guard, stdout: @stdout
        )
        @context.start!

        runner = build_runner(discovery, decision)
        return REFUSED unless confirm_duration!(runner, discovery.endpoints)

        arm_partial_report!(runner)
        # exit_on_signal: false so the main thread unwinds normally through the
        # runner's own Interrupted rescue, which is what produces a partial result
        # with everything measured so far still attached to it.
        lifecycle.trap!(exit_on_signal: false) { await_main_thread }

        result = runner.run(endpoints: discovery.endpoints)
        return dry_run_finished(result) if dry_run?

        finish(result, discovery)
      end

      # A DRY RUN WRITES NO REPORT, for the same reason it persists no history record:
      # it issued no requests, so every measurement in it is `inconclusive` and every
      # endpoint unmeasured. A file like that sitting in the report directory is
      # indistinguishable from a real run that found an API-wide problem, and it is
      # the most recent one -- so the next person to open "the latest report" reads a
      # document about a run that never happened. The matrix the runner just printed
      # IS the dry run's output.
      def dry_run_finished(result)
        @stdout.puts ""
        @stdout.puts "loadwright: dry run only — nothing was requested and no report was written."
        @stdout.puts "  re-run with --execute to measure #{result.summary[:endpoints]} endpoint(s)."
        OK
      end

      def build_runner(discovery, decision)
        Engine::LoadRunner.new(
          config: config,
          context: @context,
          guard: resource_guard,
          seeder: seeder,
          identities: Seeding::IdentityPool.new(config: config, stdout: @stdout),
          resolver: Discovery::PathParamResolver.new(config: config),
          lifecycle: lifecycle,
          containment: @containment,
          run_store: History::RunStore.new(config: config, lifecycle: lifecycle),
          # Carried into the report so the run's provenance survives the terminal:
          # which environment was detected, which layers were cleared, and what
          # discovery actually found (production-safety.md; CLAUDE.md section 2).
          safety_decision: decision,
          discovery: discovery_summary(discovery),
          stdout: @stdout
        ).tap { |runner| runner.warnings.concat(discovery.warnings) }
      end

      def discovery_summary(discovery)
        {
          endpoint_count: discovery.endpoints.length,
          by_source: discovery.by_source.reject { |_, count| count.zero? },
          skipped: discovery.skipped.map { |o| { endpoint: o.endpoint.to_s, reason: o.reason } },
          only: @options[:only]
        }.compact
      end

      def seeder
        @seeder ||= Seeding::FactoryBotSeeder.new(config: config, lifecycle: lifecycle, stdout: @stdout)
      end

      def resource_guard
        @resource_guard ||= Engine::ResourceGuard.new(
          config: config, poller: Engine::HealthPoller.new(config: config), stdout: @stdout
        )
      end

      # CLAUDE.md corollary 7: nobody should discover a four-hour run by waiting
      # through it. The estimate is printed for every real run and gated above the
      # configured threshold.
      #
      # A non-interactive terminal PROCEEDS with a warning rather than refusing. This
      # is deliberately different from the production gate, which refuses when it
      # cannot prompt -- that one is a safety decision about irreversible harm, this
      # one is a courtesy about someone's afternoon. Refusing here would break every
      # piped or scripted invocation of a tool whose whole point is to be run locally.
      def confirm_duration!(runner, endpoints)
        return true if dry_run?

        estimate = runner.estimate(endpoints)
        @stdout.puts estimate_lines(estimate)
        return true if estimate.estimated_minutes < config.long_run_confirmation_threshold_minutes.to_f

        prompt_for_long_run(estimate)
      end

      def estimate_lines(estimate)
        lines = [format("loadwright: %<cells>d cell(s), %<requests>d request(s), estimated %<minutes>.1f minute(s)",
                        cells: estimate.cells, requests: estimate.requests, minutes: estimate.estimated_minutes)]
        lines << "  #{resource_guard.describe_budget}"
        if estimate.mutating_requests.positive?
          lines << "  #{estimate.mutating_requests} of them MUTATING (allow_mutating_requests is on)"
        end
        lines
      end

      def prompt_for_long_run(estimate)
        unless @stdin.respond_to?(:tty?) && @stdin.tty?
          @stdout.puts "loadwright: this run is estimated at #{estimate.estimated_minutes} minute(s), over the " \
                       "#{config.long_run_confirmation_threshold_minutes}-minute confirmation threshold. " \
                       "Standard input is not a terminal, so it proceeds without asking -- interrupt with " \
                       "Ctrl-C if that is not what you wanted."
          return true
        end

        @stdout.print "This run is estimated at #{estimate.estimated_minutes} minute(s). Continue? [y/N] "
        @stdout.flush
        answer = @stdin.gets
        return true if answer.to_s.strip.casecmp("y").zero?

        @stderr.puts "loadwright: not running. Lower scale_factors, concurrency_levels, or " \
                     "requests_per_endpoint_per_level, or raise long_run_confirmation_threshold_minutes."
        false
      end

      # ---------------------------------------------------------------- the output

      def finish(result, discovery)
        # Discovery's skips are outcomes with reasons, and they belong in the report
        # rather than in terminal scrollback -- an endpoint that was never exercised
        # is the coverage gap a reader most needs to know about.
        result.outcomes.concat(discovery.skipped)

        paths = write_reports(result)
        @reports_written = true

        print_summary(result, paths)
        exit_code_for(result)
      end

      # THE INTERRUPT HANDOFF.
      #
      # Runs on the signal watcher thread, before Lifecycle tears anything down.
      # Without it, an interrupt produced TWO reports: the watcher fired the
      # partial-report hook while the main thread was still inside the runner's
      # Interrupted rescue, so the `@reports_written` guard was read before the thing
      # it guards had happened, and both threads called into the same runner's
      # `assemble_result` at once.
      #
      # So the watcher WAITS instead. The main thread is not stuck -- the engine polls
      # for interrupts between requests precisely so it can unwind normally -- and
      # letting it finish gives one writer, one complete partial report, and no
      # teardown racing the analysis that describes what teardown is about to delete.
      #
      # The timeout is what keeps this from turning a Ctrl-C into a hang. If it
      # expires the main thread really is wedged, and the last-resort hook below
      # writes whatever was measured.
      def await_main_thread
        deadline = Time.now + FINISH_GRACE_SECONDS
        @finish_lock.synchronize do
          until @main_thread_done
            remaining = deadline - Time.now
            break if remaining <= 0

            @finished.wait(@finish_lock, remaining)
          end
        end
      end

      def release_main_thread!
        @finish_lock.synchronize do
          @main_thread_done = true
          @finished.broadcast
        end
      end

      def write_reports(result)
        Array(config.report_formats).filter_map do |format|
          renderer = RENDERERS[format.to_sym]
          next @stderr.puts("loadwright: unknown report format #{format.inspect}; skipping") if renderer.nil?

          renderer.new(config: config).write!(result, path: report_path(format))
        end
      end

      RENDERERS = {
        html: Reporting::HtmlReport,
        markdown: Reporting::MarkdownReport,
        json: Reporting::JsonReport
      }.freeze

      EXTENSIONS = { html: "html", markdown: "md", json: "json" }.freeze

      # One timestamp for the whole run, so the HTML, Markdown and JSON of a single
      # run share a basename and sort together. Computed once and memoised -- deriving
      # it per format lets a run that crosses a second boundary write three files that
      # look like three runs.
      def report_path(format)
        @stamp ||= Time.now.strftime(config.report_filename_pattern)
        File.join(config.report_output_dir.to_s, "#{@stamp}.#{EXTENSIONS.fetch(format.to_sym, format.to_s)}")
      end

      def print_summary(result, paths)
        summary = result.summary
        @stdout.puts ""
        @stdout.puts "loadwright: #{summary[:endpoints]} endpoint(s) — " \
                     "#{summary[:healthy]} healthy, #{summary[:has_findings]} with findings, " \
                     "#{summary[:inconclusive]} inconclusive"
        @stdout.puts "  PARTIAL RUN: #{result.aborted_reason}" if result.aborted?
        top_findings(result)
        paths.each { |path| @stdout.puts "  report: #{path}" }
      end

      def top_findings(result)
        result.ranked_findings.first(3).each do |entry|
          @stdout.puts "  #{entry[:endpoint]}: #{entry[:finding].kind}"
        end
      end

      # reporting.md: the exit code is a convenience for someone scripting around it,
      # not the tool's interface. So it is deliberately conservative.
      #
      # INCONCLUSIVE DOES NOT FAIL. An endpoint the run could not measure is a gap in
      # coverage, not a defect in the app, and exiting non-zero for it would train
      # people to ignore the exit code -- the first unauthenticated endpoint in a
      # suite would make every run "fail" forever.
      #
      # ADVISORY FINDINGS DO NOT FAIL EITHER (response-analysis.md): an over-fetch
      # hint may never veto a clean verdict, and that has to hold for the exit code
      # as much as for the outcome state.
      FAILING_KINDS = %i[n_plus_one_slope n_plus_one_pattern_match].freeze

      def exit_code_for(result)
        return INTERRUPTED if lifecycle.interrupted?
        return FINDINGS if result.aborted?

        kinds = result.ranked_findings.map { |entry| entry[:finding].kind }
        return FINDINGS if config.fail_on_n_plus_one && kinds.any? { |kind| FAILING_KINDS.include?(kind) }
        return FINDINGS if kinds.include?(:latency_budget_exceeded)

        OK
      end

      def no_endpoints(discovery)
        @stderr.puts <<~MSG.strip
          loadwright: no endpoints to exercise.
          #{discovery.skipped.length} endpoint(s) were discovered but skipped; see the warnings above.
          The usual causes are an empty openapi_spec_paths, no recording from `loadwright record`,
          and excluded_paths filtering more than you meant it to.
        MSG
        REFUSED
      end

      # ------------------------------------------------------------------ teardown

      # LAST RESORT ONLY. The normal interrupted path writes its report on the main
      # thread, which `await_main_thread` above waits for -- so by the time teardown
      # runs this hook, `@reports_written` is true and it does nothing. It fires only
      # when the main thread never got there at all, which is the one case a run that
      # measured something would otherwise vanish without a trace.
      def arm_partial_report!(runner)
        lifecycle.register("partial report") do
          next if @reports_written || !config.write_partial_report_on_abort

          result = runner.partial_result
          next if result.nil?

          write_reports(result).each { |path| @stdout.puts "loadwright: partial report written to #{path}" }
        end
      end

      def teardown!
        @context&.stop!
        @seeder&.cleanup!
        @resource_guard&.stop!
        lifecycle.run_teardown!
        lifecycle.untrap!
      rescue StandardError => e
        # Teardown failures are reported, never raised: raising here replaces the real
        # error (or the real result) with an error about cleaning up after it.
        @stderr.puts "loadwright: teardown failed: #{e.class}: #{e.message}"
      end
    end
  end
end

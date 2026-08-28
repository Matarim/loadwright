# frozen_string_literal: true

require "optparse"
require "loadwright/version"
require "loadwright/errors"
require "loadwright/history/run_store"
require "loadwright/history/comparator"
require "loadwright/reporting/comparison_report"
require "loadwright/cli/run_command"
require "loadwright/cli/record_command"
require "loadwright/cli/init_command"

module Loadwright
  # Command-line entry point.
  #
  # The command and flag surface is fixed by AGENTS.md section 7 — agents are
  # told these exact invocations, so they are not free to drift. Argument
  # parsing and --help are real; every command body is a stub.
  #
  # This class is ARGUMENT PARSING AND DISPATCH ONLY. The two commands with real
  # orchestration behind them live next door in cli/run_command.rb and
  # cli/record_command.rb, so the mapping from argv to behaviour stays readable and
  # the pipeline assembly is testable without going through a command line.
  #
  # Two behaviours specified elsewhere belong to the `run` path and are implemented
  # in RunCommand:
  #
  #   * The single SIGINT/SIGTERM trap, delegating to Loadwright::Lifecycle.
  #     Subsystems register teardown callbacks; they do not trap signals themselves
  #     (CLAUDE.md corollary 6).
  #
  #   * The estimated duration and worst-case backoff budget printed before any
  #     requests are issued, with a confirmation above
  #     config.long_run_confirmation_threshold_minutes (CLAUDE.md corollary 7).
  class CLI
    COMMANDS = {
      "init" => "Write config/initializers/loadwright.rb with the settings most apps need",
      "run" => "Discover, seed, and exercise endpoints under the scale x concurrency matrix",
      "record" => "Run the app's own specs and record the requests they make, for discovery",
      "runs" => "List persisted run records (`runs list`)",
      "baseline" => "Designate a run as the comparison baseline (`baseline set <run_id>`)",
      "compare" => "Compare two runs, or the current run against the baseline"
    }.freeze

    def self.start(argv, stdout: $stdout, stderr: $stderr)
      new(stdout: stdout, stderr: stderr).start(argv)
    end

    def initialize(stdout: $stdout, stderr: $stderr)
      @stdout = stdout
      @stderr = stderr
      @options = { dry_run: true, execute: false, risk_acknowledged: false, only: nil, mode: nil }
    end

    def start(argv)
      # UNBUFFERED. A run prints progress over minutes, and block buffering (which is
      # what a pipe or a redirect gets, unlike a terminal) holds all of it until the
      # process exits -- so `loadwright run > run.log` shows nothing until it is over,
      # and any stderr message lands ahead of the stdout lines that led up to it. For
      # a tool whose output IS the interface, that ordering is a defect.
      @stdout.sync = true if @stdout.respond_to?(:sync=)

      argv = argv.dup
      parser = build_parser
      parser.order!(argv)
      command = argv.shift

      if @options[:version]
        @stdout.puts "loadwright #{Loadwright::VERSION}"
        return 0
      end

      if command.nil? || @options[:help]
        @stdout.puts parser
        return command.nil? && !@options[:help] ? 1 : 0
      end

      unless COMMANDS.key?(command)
        @stderr.puts "unknown command: #{command}"
        @stderr.puts parser
        return 1
      end

      # Parsed AGAIN after the command is removed, because `order!` stops at the first
      # non-option -- so `loadwright compare --baseline` leaves the flag sitting in argv
      # where dispatch would read it as a run id. Users put flags after the command;
      # both orders now work.
      parser.order!(argv)

      dispatch(command, argv)
    end

    private

    def dispatch(command, argv)
      case command
      when "runs" then cmd_runs(argv)
      when "baseline" then cmd_baseline(argv)
      when "compare" then cmd_compare(argv)
      when "run" then cmd_run
      when "record" then cmd_record
      when "init" then cmd_init
      end
    end

    # ---------------------------------------------------------------- run/record

    def cmd_run
      RunCommand.new(options: @options, stdout: @stdout, stderr: @stderr).call
    end

    def cmd_record
      RecordCommand.new(options: @options, stdout: @stdout, stderr: @stderr).call
    end

    def cmd_init
      InitCommand.new(options: @options, stdout: @stdout, stderr: @stderr).call
    end

    # --------------------------------------------------------------------- runs

    def cmd_runs(argv)
      subcommand = argv.shift || "list"
      unless subcommand == "list"
        @stderr.puts "unknown subcommand: runs #{subcommand} (expected: runs list)"
        return 1
      end

      records = store.list
      if records.empty?
        @stdout.puts "no runs recorded yet in #{store.directory}"
        return 0
      end

      baseline_id = store.baseline&.fetch("run_id", nil)
      records.each { |record| @stdout.puts run_line(record, baseline_id) }
      0
    end

    def run_line(record, baseline_id)
      summary = record.summary
      marks = []
      marks << "BASELINE" if record.run_id == baseline_id
      marks << "dirty" if record.dirty?
      marks << "ABORTED" if record.aborted?

      format(
        "%<id>s  %<sha>-8s  %<healthy>d healthy / %<findings>d with findings / %<inconclusive>d " \
        "inconclusive%<marks>s",
        id: record.run_id, sha: record.git_sha || "-",
        healthy: summary["healthy"].to_i, findings: summary["has_findings"].to_i,
        inconclusive: summary["inconclusive"].to_i,
        marks: marks.empty? ? "" : "  [#{marks.join(', ')}]"
      )
    end

    # ----------------------------------------------------------------- baseline

    def cmd_baseline(argv)
      subcommand = argv.shift
      unless subcommand == "set"
        @stderr.puts "unknown subcommand: baseline #{subcommand} (expected: baseline set <run_id>)"
        return 1
      end

      run_id = argv.shift
      if run_id.nil?
        @stderr.puts "baseline set needs a run id (see `loadwright runs list`)"
        return 1
      end

      record = store.find(run_id)
      if record.nil?
        @stderr.puts "no such run: #{run_id}"
        return 1
      end

      floor = measure_noise_floor(record)
      store.set_baseline!(record.run_id, noise_floor: floor)
      @stdout.puts "baseline set to #{record.run_id} (#{record.git_sha || 'no sha'})"
      @stdout.puts noise_floor_message(floor)
      0
    end

    # THE NOISE FLOOR. run-comparison.md: without one, regression_threshold_pct is a
    # guess about what this machine's jitter looks like. With one, the tool knows.
    #
    # It is measured from a SECOND run on the same commit -- two runs of identical code
    # differ only by noise, so the spread between them IS the noise. Nothing is
    # fabricated when there is no second run; the user is told what to do instead.
    def measure_noise_floor(baseline, exclude: [])
      excluded = ([baseline.run_id] + Array(exclude)).compact
      sibling = store.list.find do |record|
        !excluded.include?(record.run_id) && record.git_sha == baseline.git_sha &&
          record.config_fingerprint == baseline.config_fingerprint
      end
      return nil if sibling.nil?

      pairs = paired_latencies(sibling, baseline)
      floor = Analysis::Statistics.new(config: configuration).noise_floor_from(pairs)
      floor.value_or(nil)
    end

    def paired_latencies(before, after)
      keys = before.endpoint_keys & after.endpoint_keys
      comparator = History::Comparator.new(config: configuration)

      keys.flat_map do |key|
        old_cells = comparator.cells_by_shape(before, key)
        new_cells = comparator.cells_by_shape(after, key)

        (old_cells.keys & new_cells.keys).filter_map do |shape|
          [old_cells[shape].dig("latency_ms", "p50"), new_cells[shape].dig("latency_ms", "p50")]
        end
      end
    end

    def noise_floor_message(floor)
      return format("  measured noise floor: %<pct>.1f%% (from a second run on the same commit)",
                    pct: floor * 100) if floor

      "  no second run on this commit was found, so the noise floor is unmeasured and comparisons " \
        "will fall back to regression_threshold_pct alone. Run the suite again on this commit and " \
        "re-run `baseline set` to measure it -- without it, the threshold is a guess."
    end

    # ------------------------------------------------------------------ compare

    def cmd_compare(argv)
      before, after = resolve_comparison(argv)
      return 1 if before.nil?

      floor = comparison_noise_floor(before, after)
      result = History::Comparator.new(config: configuration).compare(before, after, noise_floor: floor)

      print_comparison(before, after, result)

      # A comparison that CANNOT BE COMPUTED is an error, never a silent pass -- even
      # where someone has wired this into a script (run-comparison.md, exit codes).
      return 2 unless result.comparable?

      configuration.fail_on_regression && result.regressed? ? 1 : 0
    end

    # THE FLOOR WAS ONLY EVER AVAILABLE TO PEOPLE WHO HAD SET A BASELINE.
    #
    # `baseline set` measures the machine's run-to-run spread and stores it; `compare`
    # read it from there and from nowhere else. So a straight `compare <a> <b>` on a
    # machine with plenty of history fell back to regression_threshold_pct alone --
    # the threshold this class's own documentation calls a guess -- and reported a
    # laptop's afternoon as ~30 regressions. The measurement existed; the path that
    # needed it could not reach it.
    #
    # The stored value still wins: it is the floor the user deliberately established.
    # NOT MEASURED FROM THE PAIR UNDER COMPARISON, which would be circular -- the floor
    # is the max spread across the pair, so using it on that same pair defines every
    # one of its own deltas to be noise. It comes from a third run on the same commit
    # and configuration, which is the same non-circular rule `baseline set` follows.
    def comparison_noise_floor(before, after)
      stored = store.baseline&.fetch("noise_floor", nil)
      return stored if stored

      # A non-nil sha is REQUIRED here, unlike in `baseline set`. There, the user named
      # the run and is told what was measured. Here it is automatic and silent, and
      # `nil == nil` would match every run in a repository without git -- borrowing a
      # floor from an unrelated run and raising the bar a real regression has to clear.
      return nil if before.git_sha.nil?

      floor = measure_noise_floor(before, exclude: [after.run_id])
      @stdout.puts "loadwright: no baseline noise floor is set; measured " \
                   "#{(floor * 100).round(1)}% from another run on this commit." if floor
      floor
    end

    def resolve_comparison(argv)
      if @options[:baseline]
        baseline = store.baseline_record
        latest = store.latest
        return missing("no baseline is set; use `loadwright baseline set <run_id>`") if baseline.nil?
        return missing("no runs recorded yet") if latest.nil?
        return missing("the latest run IS the baseline; there is nothing to compare it against") if
          latest.run_id == baseline.run_id

        return [baseline, latest]
      end

      a, b = argv.shift(2)
      return missing("compare needs two run ids, or --baseline") if a.nil? || b.nil?

      before = store.find(a)
      after = store.find(b)
      return missing("no such run: #{a}") if before.nil?
      return missing("no such run: #{b}") if after.nil?

      [before, after]
    end

    def missing(message)
      @stderr.puts message
      [nil, nil]
    end

    # Rendered by ComparisonReport, so the terminal, a PR description, and the HTML
    # file all order the sections the same way. The ordering is load-bearing -- state
    # changes come before "resolved" so an endpoint that became unmeasurable is not
    # read as a fix -- and duplicating it here would let the two drift.
    def print_comparison(before, after, result)
      @stdout.puts Reporting::ComparisonReport.new(config: configuration)
                                              .render(result, before: before, after: after)
    end

    def configuration = Loadwright.configuration

    def store = @store ||= History::RunStore.new(config: configuration)

    def build_parser
      OptionParser.new do |o|
        o.banner = "Usage: loadwright <command> [options]"
        o.separator ""
        o.separator "Commands:"
        COMMANDS.each { |name, desc| o.separator format("    %-10s %s", name, desc) }
        o.separator ""
        o.separator "Options:"

        o.on("--dry-run", "Resolve everything, send zero requests (default)") do
          @options[:dry_run] = true
          @options[:execute] = false
        end
        o.on("--execute", "Actually issue requests") do
          @options[:execute] = true
          @options[:dry_run] = false
        end
        o.on("--i-understand-the-risk", "Required for any run outside enabled_environments") do
          @options[:risk_acknowledged] = true
        end
        o.on("--only PATTERN", "Restrict to paths matching PATTERN") { |v| @options[:only] = v }
        o.on("--mode MODE", %w[in_process http], "Override config.execution_mode for this run") do |v|
          @options[:mode] = v.to_sym
        end
        # APPENDS. It used to overwrite, so `--specs a --specs b` silently recorded
        # only b -- recording less than was asked for, without saying so.
        o.on("--specs PATH", "For `record`: spec path to run and capture (repeatable)") do |v|
          (@options[:specs] ||= []) << v
        end
        # `record` runs the host's specs against the database the CLI booted into, and
        # asks first when a distinct test database is declared and will not be reached.
        # This is how you answer that non-interactively.
        o.on("--accept-database-writes",
             "For `record`: acknowledge that your specs will run against the booted database") do
          @options[:accept_database_writes] = true
        end
        # The long-run prompt already PROCEEDS on a non-TTY -- it is a courtesy about
        # someone's afternoon, not a safety decision about irreversible harm. But
        # reaching that path meant detaching stdin, which changes how every other
        # prompt in the run behaves in order to answer one of them. A flag says the
        # same thing without reshaping the process.
        o.on("--accept-long-run",
             "For `run`: accept a run estimated over long_run_confirmation_threshold_minutes") do
          @options[:accept_long_run] = true
        end
        o.on("--full", "For `init`: write the complete annotated key surface") { @options[:full] = true }
        o.on("--force", "For `init`: overwrite an existing initializer") { @options[:force] = true }
        o.on("--baseline", "For `compare`: compare against the designated baseline") do
          @options[:baseline] = true
        end
        o.on("-v", "--version", "Print version") { @options[:version] = true }
        o.on("-h", "--help", "Print this message") { @options[:help] = true }
      end
    end
  end
end

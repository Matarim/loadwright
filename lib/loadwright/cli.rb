# frozen_string_literal: true

require "optparse"
require "loadwright/version"
require "loadwright/errors"

module Loadwright
  # Command-line entry point.
  #
  # The command and flag surface is fixed by AGENTS.md section 7 — agents are
  # told these exact invocations, so they are not free to drift. Argument
  # parsing and --help are real; every command body is a stub.
  #
  # Two behaviours specified elsewhere belong to this layer and are noted here
  # so they are not forgotten when the bodies land:
  #
  #   * The single SIGINT/SIGTERM trap is installed here and delegates to
  #     Loadwright::Lifecycle. Subsystems register teardown callbacks; they do
  #     not trap signals themselves (CLAUDE.md corollary 6).
  #
  #   * Before any run, print the estimated duration and worst-case backoff
  #     budget, and prompt for confirmation above
  #     config.long_run_confirmation_threshold_minutes (CLAUDE.md corollary 7).
  #
  # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
  class CLI
    COMMANDS = {
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

      dispatch(command, argv)
    end

    private

    def dispatch(command, _argv)
      raise NotImplementedError,
            "`loadwright #{command}` is not implemented yet. This is a pre-release scaffold; " \
            "see CLAUDE.md section 6 for what has been built."
    end

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
        o.on("--specs PATH", "For `record`: spec directory to run and capture") { |v| @options[:specs] = v }
        o.on("--baseline", "For `compare`: compare against the designated baseline") do
          @options[:baseline] = true
        end
        o.on("-v", "--version", "Print version") { @options[:version] = true }
        o.on("-h", "--help", "Print this message") { @options[:help] = true }
      end
    end
  end
end

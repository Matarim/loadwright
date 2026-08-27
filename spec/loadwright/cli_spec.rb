# frozen_string_literal: true

require "loadwright/cli"
require "stringio"

RSpec.describe Loadwright::CLI do
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  def run(*argv)
    described_class.start(argv, stdout: stdout, stderr: stderr)
  end

  describe "--help" do
    it "lists the commands AGENTS.md tells agents to use" do
      run("--help")

      %w[run record runs baseline compare].each do |command|
        expect(stdout.string).to include(command)
      end
    end

    it "documents the safety flags" do
      run("--help")

      expect(stdout.string).to include("--dry-run")
      expect(stdout.string).to include("--execute")
      expect(stdout.string).to include("--i-understand-the-risk")
    end
  end

  describe "--version" do
    it "prints the version" do
      expect(run("--version")).to eq(0)
      expect(stdout.string).to include(Loadwright::VERSION)
    end
  end

  describe "with no command" do
    it "prints usage and exits non-zero" do
      expect(run).to eq(1)
      expect(stdout.string).to include("Usage: loadwright")
    end
  end

  describe "with an unknown command" do
    it "says so and exits non-zero" do
      expect(run("obliterate")).to eq(1)
      expect(stderr.string).to include("unknown command: obliterate")
    end
  end

  # Dispatch only. What `run` and `record` DO is covered by run_command_spec and by
  # cli_end_to_end_spec, which drives the real binary against a real Rails app --
  # this is just the argv-to-command mapping.
  describe "dispatch" do
    it "hands `run` to RunCommand with the parsed options" do
      command = instance_double(Loadwright::CLI::RunCommand, call: 0)
      allow(Loadwright::CLI::RunCommand).to receive(:new) do |options:, **|
        expect(options).to include(execute: true, only: "/api/v1/orders")
        command
      end

      expect(run("run", "--execute", "--only", "/api/v1/orders")).to eq(0)
    end

    it "hands `record` to RecordCommand with the spec path" do
      command = instance_double(Loadwright::CLI::RecordCommand, call: 0)
      allow(Loadwright::CLI::RecordCommand).to receive(:new) do |options:, **|
        expect(options).to include(specs: ["spec/requests"])
        command
      end

      expect(run("record", "--specs", "spec/requests")).to eq(0)
    end

    # It used to OVERWRITE, so `--specs a --specs b` recorded only b -- silently
    # recording less than was asked for, which is the failure mode the rest of this
    # gem is careful to avoid.
    it "accumulates repeated --specs rather than keeping only the last" do
      command = instance_double(Loadwright::CLI::RecordCommand, call: 0)
      allow(Loadwright::CLI::RecordCommand).to receive(:new) do |options:, **|
        expect(options[:specs]).to eq(["spec/requests/a_spec.rb", "spec/requests/b_spec.rb"])
        command
      end

      expect(run("record", "--specs", "spec/requests/a_spec.rb", "--specs", "spec/requests/b_spec.rb")).to eq(0)
    end

    it "hands `init` to InitCommand" do
      command = instance_double(Loadwright::CLI::InitCommand, call: 0)
      allow(Loadwright::CLI::InitCommand).to receive(:new).and_return(command)

      expect(run("init")).to eq(0)
    end

    # The command's exit code is the process's exit code; swallowing it would make
    # every run look successful to anything scripted around it.
    it "returns the command's exit code rather than its own" do
      allow(Loadwright::CLI::RunCommand).to receive(:new)
        .and_return(instance_double(Loadwright::CLI::RunCommand, call: 3))

      expect(run("run")).to eq(3)
    end
  end

  describe "flag parsing" do
    it "rejects an invalid execution mode" do
      expect { run("--mode", "carrier_pigeon", "run") }.to raise_error(OptionParser::InvalidArgument)
    end
  end

  describe "the history commands" do
    require "tmpdir"

    around do |example|
      Dir.mktmpdir("cli-history-") { |dir| @dir = dir; example.run }
    end

    # In a `before`, not in the `around`: spec_helper resets the global configuration in
    # its own `before`, which runs INSIDE the around block. Setting it there would be
    # undone, and every example would silently share the default history directory --
    # which is exactly what happened, and it made runs from one example show up in the
    # next.
    before { Loadwright.configure { |c| c.run_history_dir = @dir } }

    let(:stdout) { StringIO.new }
    let(:stderr) { StringIO.new }

    def store = Loadwright::History::RunStore.new(config: Loadwright.configuration)

    def write_run(cells: [], endpoints: [])
      result = Loadwright::Reporting::RunResult.new(
        config: Loadwright.configuration, cells: cells, outcomes: endpoints,
        started_at: Time.now, finished_at: Time.now
      )
      # Written through the store so these exercise the real on-disk shape.
      sleep 0.01
      store.write!(result)
      store.latest
    end

    def run_cli(*argv) = described_class.start(argv, stdout: stdout, stderr: stderr)

    describe "runs list" do
      it "says so plainly when there is no history yet" do
        expect(run_cli("runs")).to eq(0)
        expect(stdout.string).to include("no runs recorded yet")
      end

      it "lists recorded runs newest first, with the three states separated" do
        write_run
        write_run

        run_cli("runs", "list")

        expect(stdout.string.lines.length).to eq(2)
        expect(stdout.string).to include("healthy", "with findings", "inconclusive")
      end

      it "marks the baseline, so it is visible without a second command" do
        record = write_run
        store.set_baseline!(record.run_id)

        run_cli("runs", "list")

        expect(stdout.string).to include("BASELINE")
      end

      it "rejects an unknown subcommand rather than guessing" do
        expect(run_cli("runs", "delete")).to eq(1)
        expect(stderr.string).to include("expected: runs list")
      end
    end

    describe "baseline set" do
      it "designates a run" do
        record = write_run

        expect(run_cli("baseline", "set", record.run_id)).to eq(0)
        expect(store.baseline["run_id"]).to eq(record.run_id)
      end

      # Without a measured floor, regression_threshold_pct is a guess about this
      # machine's jitter. The advice is the actionable half.
      it "tells the user how to measure the noise floor when it cannot" do
        record = write_run
        run_cli("baseline", "set", record.run_id)

        expect(stdout.string).to include("noise floor is unmeasured")
        expect(stdout.string).to include("Run the suite again on this commit")
      end

      it "refuses a run id that does not exist" do
        expect(run_cli("baseline", "set", "nope")).to eq(1)
        expect(stderr.string).to include("no such run")
      end

      it "needs a run id" do
        expect(run_cli("baseline", "set")).to eq(1)
      end
    end

    describe "compare" do
      it "needs two run ids, or --baseline" do
        expect(run_cli("compare")).to eq(1)
        expect(stderr.string).to include("two run ids")
      end

      it "compares two recorded runs" do
        first = write_run
        second = write_run

        expect(run_cli("compare", first.run_id, second.run_id)).to eq(0)
        expect(stdout.string).to include(first.run_id, second.run_id)
        expect(stdout.string).to include("No regressions.")
      end

      # A comparison that CANNOT BE COMPUTED is an error, never a silent pass --
      # including where someone has wired this into a script.
      it "exits 2 and refuses when the runs are not comparable" do
        first = write_run
        Loadwright.configure { |c| c.concurrency_levels = [1, 20] }
        second = write_run

        expect(run_cli("compare", first.run_id, second.run_id)).to eq(2)
        expect(stdout.string).to include("Not comparable", "concurrency_levels")
        expect(stdout.string).to include("would look meaningful and would not be")
      end

      it "compares the latest run against the baseline" do
        first = write_run
        store.set_baseline!(first.run_id)
        write_run

        expect(run_cli("compare", "--baseline")).to eq(0)
      end

      it "says what to do when no baseline is set" do
        write_run

        expect(run_cli("compare", "--baseline")).to eq(1)
        expect(stderr.string).to include("baseline set <run_id>")
      end

      it "refuses to compare the baseline against itself" do
        record = write_run
        store.set_baseline!(record.run_id)

        expect(run_cli("compare", "--baseline")).to eq(1)
        expect(stderr.string).to include("nothing to compare")
      end
    end
  end
end

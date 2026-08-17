# frozen_string_literal: true

require "loadwright/cli/run_command"
require "tmpdir"

RSpec.describe Loadwright::CLI::RunCommand do
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }
  let(:config) { Loadwright.configuration }

  # The app is already "booted" for every example here; AppLoader has its own spec,
  # and booting a real Rails app per example would make this file a different kind of
  # test entirely.
  let(:loader) { instance_double(Loadwright::CLI::AppLoader, load!: false) }

  # An APPROVING guard, injected explicitly. Without it these examples fail closed --
  # no Rails is loaded in the suite's process, so the environment detects as
  # "unknown", which is correctly not in enabled_environments. That refusal is
  # desirable behaviour (and has its own examples below); injecting past it here
  # keeps the other examples about the thing they are actually testing.
  let(:approving_guard) do
    instance_double(
      Loadwright::Safety::EnvironmentGuard,
      approve!: Loadwright::Safety::EnvironmentGuard::Decision.new(
        approved: true, environment: "test", environment_allowlisted: true,
        production_adjacent: false, dry_run: true
      )
    )
  end

  def command(options = {})
    described_class.new(
      options: { dry_run: true, execute: false, risk_acknowledged: false, only: nil, mode: nil }.merge(options),
      stdout: stdout, stderr: stderr, stdin: StringIO.new, loader: loader, guard: approving_guard
    )
  end

  around do |example|
    Dir.mktmpdir("run-command-") do |dir|
      @dir = dir
      example.run
    end
  end

  # A `before`, not the `around` above: the suite-wide `Loadwright.reset_configuration!`
  # hook runs INSIDE the around block, so anything configured there is wiped again
  # before the example starts.
  before do
    Loadwright.configure do |c|
      c.report_output_dir = @dir
      # ActionMailer and ActiveJob are not loaded in the suite's own process, so
      # containment correctly reports itself unenforceable and aborts the run --
      # fail-closed behaviour with its own specs in side_effects/. Turning the two
      # measures off states that premise rather than leaving these examples
      # dependent on whether some earlier example happened to load Rails.
      c.suppress_mail_delivery = false
      c.suppress_background_jobs = false
    end
  end

  def report_files = Dir.glob(File.join(@dir, "*.{html,md,json}"))

  describe "when the safety guard refuses" do
    let(:guard) { instance_double(Loadwright::Safety::EnvironmentGuard) }

    before do
      allow(guard).to receive(:approve!).and_raise(Loadwright::SafetyError, "refusing to run: production")
    end

    def refusing_command
      described_class.new(
        options: { execute: true }, stdout: stdout, stderr: stderr,
        stdin: StringIO.new, loader: loader, guard: guard
      )
    end

    # A REFUSAL IS A DESIGNED OUTCOME, NOT A CRASH. Two things matter here and they
    # are easy to get wrong together: the exit code must be distinguishable from
    # "ran fine" AND from "found problems", and the output must not be a backtrace.
    # A stack trace reads as a bug in the tool and sends the user to the wrong
    # codebase; a zero exit reads as a clean bill of health for a run that never
    # happened, which is the single worst thing this tool could report.
    it "exits 3 — distinct from both success and findings" do
      expect(refusing_command.call).to eq(described_class::REFUSED)
      expect(described_class::REFUSED).not_to eq(described_class::OK)
      expect(described_class::REFUSED).not_to eq(described_class::FINDINGS)
    end

    it "prints the refusal, not a backtrace" do
      refusing_command.call

      expect(stderr.string).to include("refusing to run: production")
      expect(stderr.string).not_to include(".rb:")
    end

    it "issues no requests and writes no report" do
      expect(Loadwright::Execution::ExecutionContext).not_to receive(:build)

      refusing_command.call

      expect(report_files).to be_empty
    end
  end

  describe "when discovery finds nothing to exercise" do
    before do
      allow_any_instance_of(Loadwright::Discovery::Pipeline).to receive(:discover).and_return(
        Loadwright::Discovery::Pipeline::Result.new(
          endpoints: [], skipped: [], warnings: [], by_source: {}
        )
      )
    end

    # Exiting 0 here would report an API with no endpoints as an API with no
    # problems. The usual cause is a configuration mistake, so the message names the
    # three that account for nearly all of them.
    it "refuses rather than reporting a clean run over zero endpoints" do
      expect(command(execute: true).call).to eq(described_class::REFUSED)
      expect(stderr.string).to include("no endpoints to exercise")
      expect(stderr.string).to include("excluded_paths")
    end
  end

  # Every designed refusal prints its message, not a backtrace. Catching only
  # SafetyError left three of these escaping as stack traces -- and all three have
  # carefully written messages that exist precisely so the user does not need one.
  describe "the other designed refusals" do
    {
      "a named OpenAPI document that is not there" =>
        [Loadwright::DiscoveryError, "openapi_spec_paths names docs/api.yaml, which does not exist"],
      "auth_token_provider raising" =>
        [Loadwright::SeedingError, "config.auth_token_provider raised NoMethodError"],
      "the app under test not booting" =>
        [Loadwright::ServerError, "could not boot the app under test"]
    }.each do |scenario, (error_class, message)|
      it "reports #{scenario} as a refusal rather than a crash" do
        allow_any_instance_of(Loadwright::Discovery::Pipeline).to receive(:discover).and_raise(error_class, message)

        expect(command(execute: true).call).to eq(described_class::REFUSED)
        expect(stderr.string).to include(message)
        expect(stderr.string).not_to include(".rb:")
      end
    end

    # A bug in the gem is not a refusal, and hiding its backtrace would make it
    # much harder to report.
    it "lets a genuine bug surface with its backtrace" do
      allow_any_instance_of(Loadwright::Discovery::Pipeline)
        .to receive(:discover).and_raise(NoMethodError, "undefined method 'oops'")

      expect { command(execute: true).call }.to raise_error(NoMethodError)
    end
  end

  # THE FIRST COMMAND A NEW USER RUNS. Found by installing the built gem into a
  # fresh Rails app and following the README quickstart: `run --dry-run` aborted
  # outright, because block_outbound_http needs webmock, webmock is not a runtime
  # dependency, and abort_if_containment_unavailable defaults to true.
  #
  # A dry run issues ZERO requests. There is no mail to send, no job to enqueue and
  # no outbound call to make, so aborting one protects against a risk that cannot
  # occur -- while blocking the user from the endpoint list, which is the entire
  # point of the command and the thing the tool tells them to look at first.
  #
  # The warning is still printed, loudly, because learning this BEFORE typing
  # --execute is exactly why containment is installed during a dry run at all.
  # --execute still aborts; that path issues real requests.
  describe "when containment cannot be enforced" do
    before do
      allow_any_instance_of(Loadwright::SideEffects::Containment)
        .to receive(:install!).and_raise(Loadwright::ContainmentError, "webmock is not available")
      allow_any_instance_of(Loadwright::Discovery::Pipeline).to receive(:discover).and_return(
        Loadwright::Discovery::Pipeline::Result.new(
          endpoints: [Loadwright::Discovery::Endpoint.new(path: "/api/posts", verb: :get, source: :openapi)],
          skipped: [], warnings: [], by_source: { openapi: 1 }
        )
      )
    end

    it "still shows a dry run's endpoint list, rather than refusing" do
      expect(command(execute: false).call).to eq(described_class::OK)
      expect(stdout.string).to include("DRY RUN")
    end

    it "says loudly that containment could not be enforced" do
      command(execute: false).call

      expect(stdout.string).to include("webmock is not available")
      expect(stdout.string).to include("--execute")
    end

    # The safety guarantee is unchanged where it means something.
    it "still refuses a real run" do
      expect(command(execute: true).call).to eq(described_class::REFUSED)
      expect(stderr.string).to include("webmock is not available")
    end
  end

  describe "a dry run" do
    let(:endpoints) do
      [Loadwright::Discovery::Endpoint.new(path: "/api/posts", verb: :get, source: :openapi)]
    end

    before do
      allow_any_instance_of(Loadwright::Discovery::Pipeline).to receive(:discover).and_return(
        Loadwright::Discovery::Pipeline::Result.new(
          endpoints: endpoints, skipped: [], warnings: [], by_source: { openapi: 1 }
        )
      )
    end

    # A DRY RUN WRITES NO REPORT FILE, for the same reason LoadRunner persists no
    # history record for one: it issues zero requests, so every endpoint in it is
    # `inconclusive` and every measurement absent. Such a file is indistinguishable
    # from a real run that found an API-wide problem -- and it is the NEWEST file in
    # the report directory, so the next person to open "the latest report" reads a
    # document about a run that never happened.
    #
    # This was a live bug, found by running the command rather than by unit-testing
    # it: the first real --dry-run wrote three report files.
    it "writes no report file" do
      expect(command(execute: false).call).to eq(described_class::OK)
      expect(report_files).to be_empty
    end

    it "says outright that nothing was measured, and how to measure it" do
      command(execute: false).call

      expect(stdout.string).to include("nothing was requested and no report was written")
      expect(stdout.string).to include("--execute")
    end

    it "prints the matrix it would have run" do
      command(execute: false).call

      expect(stdout.string).to include("DRY RUN")
      expect(stdout.string).to include("GET /api/posts")
    end

    # The dry run's whole purpose is to show what the real run will do, which it can
    # only do if both resolve the same list from the same code.
    it "writes no run history record either" do
      command(execute: false).call

      expect(Dir.glob(File.join(@dir, "runs", "*.json"))).to be_empty
    end
  end

  describe "the exit code after a real run" do
    def result_with(findings_kinds: [], aborted: nil, outcomes: nil)
      endpoint = Loadwright::Discovery::Endpoint.new(path: "/a", verb: :get, source: :openapi)
      outcomes ||= if findings_kinds.empty?
                     [Loadwright::EndpointOutcome.healthy(endpoint: endpoint)]
                   else
                     [Loadwright::EndpointOutcome.has_findings(
                       endpoint: endpoint,
                       findings: findings_kinds.map do |kind|
                         Loadwright::Analysis::ResponseCorrelator::Finding.new(kind: kind, detail: "d", confidence: :high)
                       end
                     )]
                   end

      Loadwright::Reporting::RunResult.new(
        config: config, cells: [], outcomes: outcomes, aborted_reason: aborted
      )
    end

    def exit_code_for(result)
      cmd = command(execute: true)
      cmd.send(:exit_code_for, result)
    end

    it "is 0 for a clean run" do
      expect(exit_code_for(result_with)).to eq(described_class::OK)
    end

    it "is 1 when a latency budget was exceeded" do
      expect(exit_code_for(result_with(findings_kinds: [:latency_budget_exceeded])))
        .to eq(described_class::FINDINGS)
    end

    it "is 1 for an N+1 only when fail_on_n_plus_one is on" do
      expect(exit_code_for(result_with(findings_kinds: [:n_plus_one_slope]))).to eq(described_class::OK)

      config.fail_on_n_plus_one = true
      expect(exit_code_for(result_with(findings_kinds: [:n_plus_one_slope]))).to eq(described_class::FINDINGS)
    end

    # INCONCLUSIVE MUST NOT FAIL THE EXIT CODE. An endpoint the run could not measure
    # is a gap in COVERAGE, not a defect in the app. Failing on it would mean the
    # first unauthenticated endpoint in a suite makes every run non-zero forever,
    # which trains people to ignore the exit code entirely -- and then the codes that
    # do mean something stop being read too.
    it "is 0 for an inconclusive endpoint" do
      endpoint = Loadwright::Discovery::Endpoint.new(path: "/a", verb: :get, source: :openapi)
      inconclusive = [Loadwright::EndpointOutcome.inconclusive(
        endpoint: endpoint, reason: :unsuccessful_status, detail: "403"
      )]

      expect(exit_code_for(result_with(outcomes: inconclusive))).to eq(described_class::OK)
    end

    # response-analysis.md: an advisory class may never veto a clean verdict, and
    # that has to hold for the exit code as much as for the outcome state.
    it "is 0 for an advisory over-fetch hint" do
      config.fail_on_n_plus_one = true

      expect(exit_code_for(result_with(findings_kinds: [:over_fetch_hint]))).to eq(described_class::OK)
    end

    it "is 1 for a run that aborted, whatever it did or did not find" do
      expect(exit_code_for(result_with(aborted: "circuit breaker"))).to eq(described_class::FINDINGS)
    end
  end
end

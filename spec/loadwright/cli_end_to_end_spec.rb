# frozen_string_literal: true

require "tmpdir"
require "open3"
require "json"

# ===========================================================================
# THE CLI, DRIVEN THE WAY A USER DRIVES IT: as a subprocess, from a Rails app's root,
# through exe/loadwright.
#
# WHY A SUBPROCESS AND NOT AN IN-PROCESS CALL. Almost everything this file covers is
# invisible to an in-process test of CLI#start:
#
#   * AppLoader booting a real Rails app from a real working directory. In the
#     suite's own process Rails is already loaded, so the boot path never executes.
#   * The initializer being what configures the run. The whole adoption story is
#     "install the gem, generate an initializer, run it" -- and every other spec in
#     this suite builds its own `Configuration.new`, so the file a real user edits is
#     exercised by nothing.
#   * The process exit code, which is a real part of the interface and cannot be
#     observed from a method return value that something else might still change.
#   * Signal handling, which needs a process to send a signal to.
#
# It is slow -- each invocation boots Rails -- so the runs are shared across the
# whole file rather than repeated per example, the same way end_to_end_spec.rb shares
# one run per transport.
# ===========================================================================
RSpec.describe "the loadwright CLI, end to end" do
  # Distinctively named on purpose. A constant assigned inside an `RSpec.describe`
  # block lands on Object, not on the example group -- so a bare `ROOT` or
  # `Invocation` here would silently overwrite, or be overwritten by, any other spec
  # file that declared the same name, and which won would depend on load order.
  # architecture_spec enforces this; last session lost an afternoon to two files
  # declaring `ASSIGNMENT` with different regexes.
  CLI_E2E_ROOT = File.expand_path("../..", __dir__)
  CLI_E2E_APP = File.join(CLI_E2E_ROOT, "examples", "sample_app")
  # Created once for the whole file and removed at the end, rather than per example
  # group: `self.class` differs inside each nested `describe`, and a per-group
  # workspace is a per-group directory nothing ever deletes.
  CLI_E2E_WORKSPACE = Dir.mktmpdir("cli-e2e-")

  CliInvocation = Struct.new(:status, :stdout, :stderr, :reports, :recording, keyword_init: true) do
    def output = "#{stdout}\n#{stderr}"

    def report(extension) = reports.find { |path| path.end_with?(".#{extension}") }

    def json = JSON.parse(File.read(report("json")))
  end

  # A database the suite's own fixture never touches, and a disposable home for the
  # generated reports.
  def self.workspace = CLI_E2E_WORKSPACE

  def self.invoke(*argv, env: {})
    # Unique per invocation, so two invocations can never write into one directory
    # and make each other's report listing wrong.
    reports_dir = Dir.mktmpdir("reports-", workspace)

    stdout, stderr, status = Open3.capture3(
      {
        "RAILS_ENV" => "test",
        "SAMPLE_APP_DATABASE" => File.join(workspace, "cli-e2e.sqlite3"),
        "SAMPLE_APP_LOADWRIGHT_CONFIG" => "1",
        "SAMPLE_APP_LOADWRIGHT_REPORT_DIR" => reports_dir
      }.merge(env),
      RbConfig.ruby, "-I#{File.join(CLI_E2E_ROOT, 'lib')}",
      File.join(CLI_E2E_ROOT, "exe", "loadwright"), *argv,
      chdir: CLI_E2E_APP
    )

    CliInvocation.new(
      status: status.exitstatus, stdout: stdout, stderr: stderr,
      reports: Dir.glob(File.join(reports_dir, "*.{html,md,json}")).sort,
      recording: File.join(reports_dir, "recorded-requests.json")
    )
  end

  def self.dry_run = @dry_run ||= invoke("run", "--dry-run")
  def self.real_run = @real_run ||= invoke("run", "--execute")

  after(:context) { FileUtils.remove_entry(CLI_E2E_WORKSPACE) if File.directory?(CLI_E2E_WORKSPACE) }

  # ===========================================================================
  describe "run --dry-run" do
    let(:invocation) { self.class.dry_run }

    it "exits 0" do
      expect(invocation.status).to eq(0), invocation.output
    end

    it "boots the host app and discovers its endpoints from the initializer's config" do
      expect(invocation.stdout).to include("booting the application")
      expect(invocation.stdout).to match(/\d+ endpoint\(s\) to exercise/)
    end

    it "prints the matrix it would have run" do
      expect(invocation.stdout).to include("DRY RUN")
      expect(invocation.stdout).to include("GET /api/v1/posts")
    end

    # ===========================================================================
    # THE DRY RUN LEAVES NO ARTIFACT. It issues zero requests, so every endpoint in
    # such a report is `inconclusive` and every measurement absent -- a document
    # indistinguishable from a real run that found an API-wide problem, sitting in
    # the report directory as the NEWEST file there.
    #
    # Found by running the command rather than by reasoning about it: the first real
    # --dry-run wrote three of them.
    # ===========================================================================
    it "writes no report file" do
      expect(invocation.reports).to be_empty
    end
  end

  # ===========================================================================
  describe "run --execute" do
    let(:invocation) { self.class.real_run }

    it "completes" do
      expect(invocation.status).to eq(0), invocation.output
    end

    it "writes every format the initializer asked for" do
      expect(invocation.reports.map { |p| File.extname(p) }).to contain_exactly(".html", ".json", ".md")
    end

    # One run, one basename. Deriving the timestamp per format lets a run that
    # crosses a second boundary write three files that look like three runs.
    it "gives all three formats the same basename" do
      expect(invocation.reports.map { |p| File.basename(p, ".*") }.uniq.length).to eq(1)
    end

    it "finds the N+1 the fixture was built to have" do
      kinds = invocation.json["endpoints"].flat_map { |e| Array(e["findings"]).map { |f| f["kind"] } }

      expect(kinds).to include("n_plus_one_pattern_match")
    end

    # The endpoint that looks healthiest to a query-counting tool: 403 in a couple of
    # milliseconds with zero queries. It must never be reported as fast.
    it "reports the always-403 endpoint as inconclusive rather than fast" do
      stats = invocation.json["endpoints"].find { |e| e["endpoint"].include?("admin/stats") }

      expect(stats["state"]).to eq("inconclusive")
    end

    # ===========================================================================
    # THE AUDIT TRAIL. production-safety.md requires every guard decision to reach
    # the report, so a run's authority to have happened is auditable after the
    # terminal is gone. RunResult has always accepted it -- but nothing passed it in,
    # because until the CLI existed nothing drove a run end to end. It was nil in
    # every report the gem could produce.
    # ===========================================================================
    it "records the safety decision that permitted the run" do
      safety = invocation.json.dig("metadata", "safety")

      expect(safety).to include("approved" => true, "environment" => "test")
      expect(safety["production_adjacent"]).to be(false)
    end

    it "records what containment was actually enforced" do
      measures = invocation.json.dig("metadata", "containment", "measures")

      expect(measures.map { |m| m["name"] }).to include("mail", "background_jobs", "outbound_http")
      expect(measures).to all(include("enforced" => true))
    end

    it "records what discovery found and what it skipped" do
      expect(invocation.json.dig("metadata", "discovery", "endpoint_count")).to be_positive
    end

    # Loadwright deletes only the rows it created, tracked by id -- never a TRUNCATE.
    it "cleans up the rows it seeded" do
      expect(invocation.stdout).to match(/deleted \d+ seeded post row/)
    end

    it "persists a run history record the compare commands can read" do
      listing = self.class.invoke("runs", "list")

      expect(listing.status).to eq(0), listing.output
      expect(listing.stdout).to match(/healthy .* inconclusive/)
    end
  end

  # ===========================================================================
  # THE ADOPTION LOOP. `record` exists so discovery can resolve path parameters from
  # requests the app's own specs really make. The proof that it worked is not the
  # file it wrote -- it is that an endpoint which was INCONCLUSIVE for want of a
  # resolvable {id} becomes measurable afterwards.
  # ===========================================================================
  describe "record --specs" do
    let(:invocation) do
      @record ||= begin
        specs = File.join(self.class.workspace, "requests")
        FileUtils.mkdir_p(specs)
        File.write(File.join(specs, "authors_spec.rb"), <<~SPEC)
          require "action_dispatch/testing/integration"

          RSpec.describe "authors" do
            include ActionDispatch::Integration::Runner
            def app = SampleApp::Application

            it "shows an author" do
              author = Author.create!(name: "A", slug: "slug-\#{SecureRandom.hex(4)}")
              get "/api/v1/authors/\#{author.id}"
              expect(response.status).to eq(200)
            end
          end
        SPEC

        self.class.invoke("record", "--specs", specs)
      end
    end

    it "exits 0 and reports what it captured" do
      expect(invocation.status).to eq(0), invocation.output
      expect(invocation.stdout).to match(/recorded \d+ request/)
    end

    it "writes a recording keyed by path template, not by concrete path" do
      recorded = JSON.parse(File.read(invocation.recording))

      expect(recorded["requests"].map { |r| r["template"] }).to include("/api/v1/authors/{id}")
    end

    # Cookies and filtered params are redacted at COLLECTION time, so a secret never
    # reaches the persisted file in the first place.
    it "redacts as it records" do
      recorded = JSON.parse(File.read(invocation.recording))

      expect(recorded["requests"].first["headers"]["Cookie"]).to eq("[FILTERED]")
    end
  end
end

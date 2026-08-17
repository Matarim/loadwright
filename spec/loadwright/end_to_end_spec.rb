# frozen_string_literal: true

require "shellwords"

# THE STANDING GATE, required by execution-modes.md and CLAUDE.md section 6: at least
# one REAL end-to-end run per transport against examples/sample_app.
#
# Why this is not optional. The Null transport plus a scripted collector makes the
# whole pipeline fast to test, and fast test infrastructure drifts from reality
# PRECISELY BECAUSE it is convenient — a suite that only ever runs against doubles
# stays green while the real path breaks. Everything here goes through a real Rails
# app, a real database, real SQL, and (for :http) a real socket and a real child
# process.
#
# The assertions are about FINDINGS, not plumbing: does the run actually notice the
# defects the fixture was built to have, and does it correctly decline to call the 403
# endpoint healthy?
#
# Each transport runs ONCE and every example reads the same result. Booting a server
# per example is both slow and misleading — 12 boots would make a single boot failure
# look like 12 unrelated ones, which is exactly how the first version of this file
# wasted its time.
RSpec.describe "end-to-end against examples/sample_app", :sample_app do
  # Cached per transport for the whole suite run.
  RUNS = {}

  # A completed run plus the facts that can only be observed while it is happening.
  Recording = Struct.new(:result, :rows_after_cleanup, :server, :stdout, keyword_init: true)

  def configure(config)
    # Both scale factors deliberately EXCEED the authors endpoint's default page size
    # of 25. Below that its returned count tracks table size and the seed-scale sweep
    # is not yet flat — correct behaviour, but it means "flat against seeded scale"
    # only holds once the pages are actually full.
    config.scale_factors = [30, 90]
    config.page_size_sweep = [5, 25, 50]
    config.concurrency_levels = [1]
    config.requests_per_endpoint_per_level = 2
    config.warmup_requests = 1
    config.factory_map = { "post" => { factory: :post, trait: :with_comments } }
    config
  end

  def self.endpoints
    [
      # Unpaginated AND N+1: the seeded-scale sweep sees both.
      "/api/v1/posts",
      # Paginated AND N+1: only the page-size sweep sees it.
      "/api/v1/authors",
      # Always 403 — must be inconclusive, never the fastest endpoint in the API.
      "/api/v1/admin/stats",
      # Genuinely correct: nested, indexed, properly preloaded.
      "/api/v1/posts/{post_id}/comments"
    ].map { |path| Loadwright::Discovery::Endpoint.new(path: path, verb: :get, source: :openapi) }
  end

  def recording_for(mode)
    RUNS[mode] ||= perform_run(mode)
  end

  def perform_run(mode)
    config = configure(Loadwright::Configuration.new)
    config.execution_mode = mode
    stdout = StringIO.new
    lifecycle = Loadwright::Lifecycle.new(stderr: StringIO.new)

    SampleApp::Database.reset!

    context = build_context(mode, config, lifecycle, stdout)
    seeder = Loadwright::Seeding::FactoryBotSeeder.new(config: config, lifecycle: lifecycle, stdout: stdout)
    guard = Loadwright::Engine::ResourceGuard.new(
      config: config, poller: Loadwright::Engine::HealthPoller.new(config: config, server: context.server),
      stdout: stdout
    )

    context.start!
    result = Loadwright::Engine::LoadRunner.new(
      config: config, context: context, guard: guard, seeder: seeder,
      resolver: Loadwright::Discovery::PathParamResolver.new(config: config),
      lifecycle: lifecycle, stdout: stdout
    ).run(endpoints: self.class.endpoints)

    server = context.server&.to_h
    context.stop!
    seeder.cleanup!
    # Captured before anything else can reset the database, so "cleanup removed what it
    # created" is a real observation rather than a tautology about a fresh fixture.
    rows = { posts: Post.count, comments: Comment.count, authors: Author.count }

    Recording.new(result: result, rows_after_cleanup: rows, server: server, stdout: stdout.string)
  ensure
    guard&.stop!
    lifecycle&.run_teardown!
  end

  def build_context(mode, config, lifecycle, stdout)
    return Loadwright::Execution::ExecutionContext.build_in_process(config: config, app: sample_app) if
      mode == :in_process

    config.http_boot_timeout = 45
    rackup = File.join(SampleAppHelpers::APP_ROOT, "config.ru")
    # $PORT is expanded by the shell from the environment ServerManager passes to the
    # child, which is also how the collector secret gets in.
    config.http_server_command = "bundle exec puma -p $PORT --threads 1:5 #{Shellwords.escape(rackup)}"

    Loadwright::Execution::ExecutionContext.build_http(config: config, lifecycle: lifecycle, stdout: stdout)
  end

  def outcome_for(result, path) = result.outcomes.find { |o| o.endpoint.path == path }

  def finding_kinds(result, path)
    outcome = outcome_for(result, path)
    return [] unless outcome.has_findings?

    outcome.findings.map(&:kind)
  end

  # ===========================================================================
  shared_examples "a real run that finds the planted defects" do
    let(:recording) { recording_for(mode) }
    let(:result) { recording.result }

    it "finds the N+1 on the unpaginated endpoint" do
      expect(finding_kinds(result, "/api/v1/posts")).to include(:n_plus_one_pattern_match)
    end

    # THE ONE THAT MATTERS MOST. This endpoint's query count is flat against seeded
    # scale, so a seeded-scale slope calls it perfectly healthy. Catching it here, on a
    # real app with a real database, is what proves the page-size sweep works rather
    # than merely computing arithmetic correctly on invented numbers.
    it "finds the N+1 on the PAGINATED endpoint, which a seeded-scale slope cannot see" do
      expect(finding_kinds(result, "/api/v1/authors"))
        .to include(:n_plus_one_slope).or include(:n_plus_one_pattern_match)
    end

    it "sees the paginated endpoint's query count track RETURNED records, not table size" do
      cells = result.cells_for("GET /api/v1/authors")
      seed_scale = cells.select { |cell| cell.sweep == :seed_scale }
      page_size = cells.select { |cell| cell.sweep == :page_size && !cell.skipped? }

      # Flat across seed scales: 30 rows or 90 rows, same page, same query count.
      expect(seed_scale.map(&:median_queries).uniq.length).to eq(1)
      # Rising across page sizes: more records returned, more queries.
      expect(page_size.map(&:median_queries)).to eq(page_size.map(&:median_queries).sort)
      expect(page_size.first.median_queries).to be < page_size.last.median_queries
    end

    it "reports payload growth on the unpaginated endpoint" do
      expect(finding_kinds(result, "/api/v1/posts")).to include(:missing_pagination)
    end

    # The endpoint that looks healthiest to a query-counting tool: 403 in a couple of
    # milliseconds with zero queries.
    it "marks the always-403 endpoint inconclusive, not healthy" do
      outcome = outcome_for(result, "/api/v1/admin/stats")

      expect(outcome).to be_inconclusive
      expect(outcome.reason).to eq(:unsuccessful_status)
      expect(result.clean.map { |o| o.endpoint.path }).not_to include("/api/v1/admin/stats")
    end

    it "reports the inconclusive count separately from the healthy count" do
      expect(result.summary[:inconclusive]).to be >= 1
      expect(result.summary[:endpoints]).to eq(4)
    end

    # A run that finds problems everywhere is as untrustworthy as one that finds them
    # nowhere.
    it "does not invent findings for the genuinely correct endpoint" do
      expect(outcome_for(result, "/api/v1/posts/{post_id}/comments")).not_to be_inconclusive
      expect(finding_kinds(result, "/api/v1/posts/{post_id}/comments"))
        .not_to include(:n_plus_one_pattern_match, :missing_pagination)
    end

    it "resolved the nested endpoint's path parameter from a seeded record" do
      cells = result.cells_for("GET /api/v1/posts/{post_id}/comments")

      expect(cells).not_to be_empty
      expect(cells.map(&:median_records).compact).not_to be_empty
    end

    it "deleted every row it created and nothing else" do
      expect(recording.rows_after_cleanup).to eq(posts: 0, comments: 0, authors: 0)
    end

    it "produces a serialisable result carrying the three states and the capability record" do
      serialised = result.to_h

      expect { JSON.generate(serialised) }.not_to raise_error
      expect(serialised[:summary].keys)
        .to include(:healthy, :has_findings, :inconclusive, :quarantined, :skipped)
      expect(serialised[:metadata][:transport]).to eq(expected_transport)
      expect(serialised[:metadata][:collector]).to eq(expected_collector)
      expect(serialised[:metadata][:capabilities]).not_to be_nil
    end
  end

  # ===========================================================================
  describe ":in_process" do
    let(:mode) { :in_process }
    let(:expected_transport) { :in_process }
    let(:expected_collector) { :direct }

    include_examples "a real run that finds the planted defects"

    it "measures query counts directly, with no correlation machinery in the way" do
      expect(result.cells_for("GET /api/v1/posts").map(&:median_queries).compact).not_to be_empty
      expect(result.to_h[:metadata][:capabilities][:degraded]).to be(false)
    end

    # execution-modes.md: findings that need real concurrency are marked unavailable,
    # never reported as a number.
    it "marks concurrency-dependent capability unavailable rather than fabricating it" do
      profile = Loadwright::CapabilityProfile.derive(transport: :in_process, collector: :direct)

      expect(profile).to be_unavailable(:latency_under_concurrency)
      expect(profile).to be_unavailable(:connection_pool_exhaustion)
      expect(result.cells.map(&:actual_concurrency).uniq).to eq([1])
    end
  end

  # ===========================================================================
  describe ":http" do
    let(:mode) { :http }
    let(:expected_transport) { :http }
    let(:expected_collector) { :middleware }

    include_examples "a real run that finds the planted defects"

    # The link that makes :http mode worth using. Without the child arming its own
    # middleware from the secret in its environment, every query-derived finding comes
    # back unavailable and the run says almost nothing.
    it "gets query data back from another process, via the armed collector middleware" do
      counts = result.cells_for("GET /api/v1/posts").map(&:median_queries).compact

      expect(result.to_h[:metadata][:collector]).to eq(:middleware)
      expect(counts).not_to be_empty
      expect(counts.max).to be > 1
    end

    it "booted the target itself and armed the collector" do
      expect(recording.server).to include(booted_by_loadwright: true, collector_armed: true)
      expect(recording.stdout).to include("server healthy at")
    end

    it "left no server process behind" do
      # The teardown hook is unregistered on a clean stop, so nothing is left to kill.
      expect(recording.server[:pid]).not_to be_nil
      expect(process_alive?(recording.server[:pid])).to be(false)
    end

    it "reports true client latency, which :in_process cannot" do
      profile = Loadwright::CapabilityProfile.derive(transport: :http, collector: :middleware)

      expect(profile).to be_available(:true_client_latency)
      expect(result.cells.flat_map(&:latencies).compact).to all(be > 0)
    end

    def process_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end
  end
end

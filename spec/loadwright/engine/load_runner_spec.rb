# frozen_string_literal: true

RSpec.describe Loadwright::Engine::LoadRunner do
  let(:config) { Loadwright::Configuration.new }
  let(:stdout) { StringIO.new }

  def endpoint(path: "/api/v1/posts", verb: :get, **rest)
    Loadwright::Discovery::Endpoint.new(path: path, verb: verb, source: :openapi, **rest)
  end

  # A context over the Null transport and a scripted collector: the whole pipeline,
  # no Rails, no sockets. The real path is exercised end-to-end against
  # examples/sample_app in the e2e spec.
  def build_context(responder: nil, metrics: nil, collector_name: :direct)
    Loadwright::Execution::ExecutionContext.new(
      config: config,
      transport: Loadwright::Execution::Transport::Null.new(config: config, responder: responder),
      collector: ExecutionHelpers::ScriptedCollector.new(config: config, name: collector_name, metrics: metrics)
    )
  end

  def runner(context: build_context, **rest)
    described_class.new(config: config, context: context, stdout: stdout, **rest)
  end

  # Every GraphQL operation is a POST, so matching "POST" against the endpoint key
  # announced a hundred mutating requests before a run that issued none -- and told
  # the user allow_mutating_requests was on when it was off.
  describe "#estimate mutating count" do
    it "does not count GraphQL queries as writes" do
      query = Loadwright::Discovery::Endpoint.new(
        path: "/graphql", verb: :post, source: :graphql,
        graphql_operation: "Posts", graphql_operation_type: :query,
        request_body: { "query" => "query Posts { posts { id } }" }
      )

      expect(runner.estimate([query]).mutating_requests).to eq(0)
    end

    it "still counts a GraphQL mutation as one" do
      config.allow_mutating_requests = true
      mutation = Loadwright::Discovery::Endpoint.new(
        path: "/graphql", verb: :post, source: :graphql,
        graphql_operation: "CreatePost", graphql_operation_type: :mutation,
        request_body: { "query" => "mutation CreatePost { createPost { id } }" }
      )

      expect(runner.estimate([mutation]).mutating_requests).to be_positive
    end

    it "still counts a REST POST as one" do
      config.allow_mutating_requests = true
      post = Loadwright::Discovery::Endpoint.new(
        path: "/api/posts", verb: :post, source: :openapi, request_body: { "title" => "x" }
      )

      expect(runner.estimate([post]).mutating_requests).to be_positive
    end
  end

  # AUTHENTICATION ACTUALLY BEING SENT.
  #
  # IdentityPool#resolve! was called from nowhere in lib/ -- only from its own spec.
  # So a user configured auth_token_provider, the pool was built and handed to the
  # runner, `headers_for_next` returned {} because the tokens had never been
  # resolved, and every request went out unauthenticated. Every endpoint then came
  # back 401/403, and the report told them their token was probably misconfigured.
  #
  # It was not. The tool never sent it. That is the number-one documented first-run
  # failure, caused by the tool itself, and it is why this asserts on the header on
  # the wire rather than on the pool in isolation.
  describe "authentication" do
    let(:seen_headers) { [] }

    def capturing_context
      responder = lambda do |request|
        seen_headers << request.headers
        { status: 200, body: JSON.generate([{ "id" => 1 }]) }
      end
      build_context(responder: responder)
    end

    before { config.auth_token_provider = -> { "SECRET-TOKEN" } }

    it "sends the configured token on every request" do
      runner(context: capturing_context,
             identities: Loadwright::Seeding::IdentityPool.new(config: config))
        .run(endpoints: [endpoint])

      expect(seen_headers).not_to be_empty
      expect(seen_headers).to all(include("Authorization" => "Bearer SECRET-TOKEN"))
    end

    it "resolves the pool exactly once, not per request" do
      calls = 0
      config.auth_token_provider = -> { calls += 1; "SECRET-TOKEN" }

      runner(context: capturing_context,
             identities: Loadwright::Seeding::IdentityPool.new(config: config))
        .run(endpoints: [endpoint])

      expect(calls).to eq(1)
    end

    # A provider that returns nothing means every request is unauthenticated and the
    # whole run is a wall of 401s that says nothing about the app. Better to stop.
    it "aborts before issuing anything when the provider yields no token" do
      config.auth_token_provider = -> { nil }

      expect do
        runner(context: capturing_context,
               identities: Loadwright::Seeding::IdentityPool.new(config: config))
          .run(endpoints: [endpoint])
      end.to raise_error(Loadwright::SeedingError, /no usable token/)

      expect(seen_headers).to be_empty
    end

    it "sends nothing extra for a genuinely public API" do
      config.auth_token_provider = nil

      runner(context: capturing_context,
             identities: Loadwright::Seeding::IdentityPool.new(config: config))
        .run(endpoints: [endpoint])

      expect(seen_headers.first.keys).not_to include("Authorization")
    end
  end

  # MATRIX SHAPE. response-analysis.md requires a spec asserting on the cells the
  # engine actually generates, so a future change cannot quietly reintroduce a
  # combined matrix whose slope is unattributable.
  describe "#matrix" do
    before do
      config.scale_factors = [10, 100]
      config.page_size_sweep = [5, 25]
      config.concurrency_levels = [1, 5]
      config.allow_in_process_threading = true
    end

    let(:cells) { runner.matrix([endpoint]) }

    it "produces exactly two sweeps" do
      expect(cells.map(&:sweep).uniq).to contain_exactly(:seed_scale, :page_size)
    end

    # THE INVARIANT. If seeded rows and page size both change between cells, a rise in
    # query count cannot be attributed to either.
    it "holds page size fixed across the whole seed-scale sweep" do
      seed_scale = cells.select { |cell| cell.sweep == :seed_scale }

      expect(seed_scale.map(&:page_size).uniq).to eq([nil])
      expect(seed_scale.map(&:scale_factor).uniq).to eq([10, 100])
    end

    it "holds seed scale fixed across the whole page-size sweep" do
      page_size = cells.select { |cell| cell.sweep == :page_size }

      expect(page_size.map(&:scale_factor).uniq).to eq([100])
      expect(page_size.map(&:page_size)).to eq([5, 25])
    end

    it "never varies both axes within one sweep" do
      cells.group_by(&:sweep).each do |sweep, group|
        varying = [group.map(&:scale_factor).uniq.length > 1, group.map(&:page_size).uniq.length > 1]

        expect(varying.count(true)).to be <= 1, "#{sweep} varies both seed scale and page size"
      end
    end

    # The seed-scale sweep sends no page-size parameter, so the endpoint is measured as
    # clients actually call it — which is also what lets an unpaginated endpoint reveal
    # its payload growth.
    it "sends no page-size parameter during the seed-scale sweep" do
      expect(cells.select { |cell| cell.sweep == :seed_scale }.map(&:page_size).compact).to be_empty
    end

    # Queries-per-returned-record is a single-request property. Varying concurrency
    # alongside page size would make the slope unattributable again.
    it "runs the page-size sweep at concurrency 1" do
      expect(cells.select { |cell| cell.sweep == :page_size }.map(&:requested_concurrency).uniq).to eq([1])
    end

    it "sweeps concurrency only within the seed-scale sweep" do
      seed_scale = cells.select { |cell| cell.sweep == :seed_scale }

      expect(seed_scale.map(&:requested_concurrency).uniq).to eq([1, 5])
    end
  end

  # "A spec proving a page-size sweep against a seed scale too small to fill the
  # largest page is rejected or reported as not measurable, rather than producing a
  # flat line that reads as healthy."
  describe "a page-size sweep with too little seeded data" do
    before do
      config.scale_factors = [10, 30]
      config.page_size_sweep = [5, 25, 100]
    end

    it "is reported as not measurable, with the arithmetic spelled out" do
      subject = runner

      expect(subject).not_to be_page_size_sweep_measurable
      expect(subject.page_size_sweep_unmeasurable_reason).to include("at least as large as the biggest page (100)")
      expect(subject.page_size_sweep_unmeasurable_reason).to include("reads as healthy")
    end

    it "marks the cells skipped rather than running them" do
      cells = runner.matrix([endpoint]).select { |cell| cell.sweep == :page_size }

      expect(cells).to all(be_skipped)
    end

    it "is measurable once the seed scale covers the largest page" do
      config.scale_factors = [10, 100]

      expect(runner).to be_page_size_sweep_measurable
    end
  end

  describe "concurrency in :in_process" do
    # :in_process has no server thread pool. Threads in one process sharing a GVL do
    # not measure anything a user would experience, so a "concurrency 20" number here
    # would be actively misleading.
    it "forces the levels to [1]" do
      config.concurrency_levels = [1, 5, 20]
      context = Loadwright::Execution::ExecutionContext.new(
        config: config,
        transport: Loadwright::Execution::Transport::InProcess.new(config: config, app: ->(_) { [200, {}, [""]] }),
        collector: ExecutionHelpers::ScriptedCollector.new(config: config)
      )

      expect(runner(context: context).concurrency_levels).to eq([1])
    end

    it "honours allow_in_process_threading for someone who accepts the caveats" do
      config.concurrency_levels = [1, 5]
      config.allow_in_process_threading = true
      context = Loadwright::Execution::ExecutionContext.new(
        config: config,
        transport: Loadwright::Execution::Transport::InProcess.new(config: config, app: ->(_) { [200, {}, [""]] }),
        collector: ExecutionHelpers::ScriptedCollector.new(config: config)
      )

      expect(runner(context: context).concurrency_levels).to eq([1, 5])
    end
  end

  describe "#estimate" do
    # CLAUDE.md corollary 7: nobody should discover a four-hour run by waiting
    # through it.
    it "counts cells and requests, and estimates duration" do
      config.scale_factors = [10]
      config.page_size_sweep = [5]
      config.concurrency_levels = [1]
      config.requests_per_endpoint_per_level = 25
      config.warmup_requests = 3

      estimate = runner.estimate([endpoint])

      expect(estimate.cells).to eq(2)
      expect(estimate.requests).to eq(2 * (25 + 3))
      expect(estimate.estimated_seconds).to be > 0
    end

    it "counts mutating requests separately, since those are the dangerous ones" do
      config.allow_mutating_requests = true
      config.scale_factors = [10]
      config.page_size_sweep = [5]

      estimate = runner.estimate([endpoint(verb: :post, request_body: { "title" => "x" })])

      expect(estimate.mutating_requests).to be > 0
    end

    it "includes the guard's backoff budget, so a patient run is not mistaken for a hung one" do
      guard, = build_guard_with(config: config)

      expect(runner(guard: guard).estimate([endpoint])[:backoff_budget] ||
             runner(guard: guard).estimate([endpoint]).backoff_budget)
        .to include(:worst_case_with_jitter_ms)
    end
  end

  describe "a dry run" do
    # Layer 4's guarantee, asserted on the transport rather than on printed output.
    it "sends zero requests" do
      transport = Loadwright::Execution::Transport::Null.new(config: config, dry_run: true)
      context = Loadwright::Execution::ExecutionContext.new(
        config: config, transport: transport,
        collector: ExecutionHelpers::ScriptedCollector.new(config: config)
      )

      runner(context: context).run(endpoints: [endpoint])

      expect(transport.issued_count).to eq(0)
    end

    it "prints the resolved matrix and the estimate" do
      transport = Loadwright::Execution::Transport::Null.new(config: config, dry_run: true)
      context = Loadwright::Execution::ExecutionContext.new(
        config: config, transport: transport,
        collector: ExecutionHelpers::ScriptedCollector.new(config: config)
      )

      runner(context: context).run(endpoints: [endpoint])

      expect(stdout.string).to include("DRY RUN")
      expect(stdout.string).to include("sending zero requests")
      expect(stdout.string).to include("GET /api/v1/posts")
      expect(stdout.string).to match(/estimated \d+\.\d minute/)
    end
  end

  describe "#run" do
    before do
      config.scale_factors = [10]
      config.page_size_sweep = [5]
      config.concurrency_levels = [1]
      # Enough to support p50 (min_samples_for_percentiles defaults to 20). Below it the
      # latency detector correctly reports that it cannot answer, which makes every
      # endpoint inconclusive for a reason that has nothing to do with what is under
      # test here -- so the premise is stated rather than worked around.
      config.requests_per_endpoint_per_level = 20
      config.warmup_requests = 1
    end

    it "produces a RunResult with cells and outcomes" do
      result = runner.run(endpoints: [endpoint])

      expect(result).to be_a(Loadwright::Reporting::RunResult)
      expect(result.cells).not_to be_empty
      expect(result.outcomes.length).to eq(1)
    end

    it "records the concurrency each cell actually ran at" do
      result = runner.run(endpoints: [endpoint])

      expect(result.cells.map(&:actual_concurrency).uniq).to eq([1])
      expect(result.cells.none?(&:stepped_down?)).to be(true)
    end

    it "discards warmup requests from the recorded latencies" do
      config.requests_per_endpoint_per_level = 3
      config.warmup_requests = 2
      transport_context = build_context
      result = runner(context: transport_context).run(endpoints: [endpoint])

      seed_cell = result.cells.find { |cell| cell.sweep == :seed_scale }
      expect(seed_cell.latencies.length).to eq(3)
    end

    it "marks a 403 endpoint inconclusive rather than healthy" do
      responder = { "GET /api/v1/admin/stats" => { status: 403, body: '{"error":"forbidden"}' } }
      result = runner(context: build_context(responder: responder))
               .run(endpoints: [endpoint(path: "/api/v1/admin/stats")])

      outcome = result.outcomes.first
      expect(outcome).to be_inconclusive
      expect(outcome.reason).to eq(:unsuccessful_status)
      expect(result.clean).to be_empty
    end

    it "reports a healthy endpoint as healthy" do
      responder = ->(_) { { status: 200, body: JSON.generate(Array.new(5) { { "id" => 1 } }) } }
      result = runner(context: build_context(responder: responder, metrics: { query_count: 2 }))
               .run(endpoints: [endpoint])

      expect(result.outcomes.first).to be_healthy
      expect(result.summary).to include(healthy: 1, inconclusive: 0)
    end
  end

  describe "the circuit breaker mid-run" do
    it "aborts the remaining matrix and marks it skipped rather than omitting it" do
      config.scale_factors = [10, 100]
      config.page_size_sweep = [5]
      config.requests_per_endpoint_per_level = 20
      config.warmup_requests = 0
      breaker = Loadwright::Engine::CircuitBreaker.new(config: config)
      responder = ->(_) { { status: 500, body: '{"error":"boom"}' } }

      result = runner(context: build_context(responder: responder), breaker: breaker)
               .run(endpoints: [endpoint, endpoint(path: "/api/v1/authors")])

      expect(breaker).to be_tripped
      expect(result).to be_aborted
      expect(result.aborted_reason).to include("circuit breaker tripped")
      expect(result.outcomes.map(&:reason)).to include(:unsuccessful_status).or include(:circuit_breaker)
    end
  end

  describe "the resource guard mid-run" do
    it "steps a cell down and records the level it actually ran at" do
      config.scale_factors = [10]
      config.page_size_sweep = [5]
      config.concurrency_levels = [1, 5]
      config.allow_in_process_threading = true
      config.requests_per_endpoint_per_level = 2
      config.warmup_requests = 0

      guard = Class.new do
        def check_cell!(endpoint_key:, concurrency:)
          Loadwright::Engine::ResourceGuard::Decision.new(
            rung: concurrency > 1 ? :step_down : :proceed,
            concurrency: concurrency > 1 ? 1 : nil, reason: "scripted step-down"
          )
        end

        def quarantined?(_key) = false
        def classify(_error, concurrency:) = :other
        def record_baseline_latency(*) = nil
        def note_recovery(*) = nil
        def findings = []
        def events = []
        def to_h = { scripted: true }
      end.new

      result = runner(guard: guard).run(endpoints: [endpoint])

      stepped = result.cells.select(&:stepped_down?)
      expect(stepped).not_to be_empty
      expect(stepped.first.requested_concurrency).to eq(5)
      expect(stepped.first.actual_concurrency).to eq(1)
      expect(stepped.first.to_h[:stepped_down]).to be(true)
    end

    it "aborts the run when the guard reaches Rung 5" do
      config.scale_factors = [10]
      config.page_size_sweep = [5]
      config.warmup_requests = 0
      guard = Class.new do
        def check_cell!(**)
          Loadwright::Engine::ResourceGuard::Decision.new(rung: :abort, reason: "the database is not recovering")
        end

        def quarantined?(_key) = false
        def classify(*, **) = :other
        def record_baseline_latency(*) = nil
        def note_recovery(*) = nil
        def findings = []
        def events = []
        def to_h = {}
      end.new

      result = runner(guard: guard).run(endpoints: [endpoint])

      expect(result).to be_aborted
      expect(result.aborted_reason).to include("not recovering")
      # An aborted run must still produce output, never nothing.
      expect(result.to_h[:metadata][:aborted]).to be(true)
    end
  end

  describe "interruption" do
    # A Ctrl-C partway through must still produce a report of what was collected.
    it "writes a partial result rather than losing the run" do
      config.scale_factors = [10, 100]
      config.page_size_sweep = [5]
      config.requests_per_endpoint_per_level = 2
      config.warmup_requests = 0
      lifecycle = Loadwright::Lifecycle.new(stderr: StringIO.new)
      lifecycle.instance_variable_set(:@interrupted, true)

      result = runner(lifecycle: lifecycle).run(endpoints: [endpoint])

      expect(result).to be_aborted
      expect(result.aborted_reason).to eq("interrupted")
      expect(result.outcomes.first.reason).to eq(:interrupted)
      expect(stdout.string).to include("writing a partial report")
    end
  end

  describe "path parameters that cannot be resolved" do
    # Never send a placeholder id and then report the resulting 404 as a performance
    # result.
    it "skips the endpoint and names the parameter" do
      config.scale_factors = [10]
      config.page_size_sweep = [5]
      resolver = Loadwright::Discovery::PathParamResolver.new(config: config)

      result = runner(resolver: resolver).run(endpoints: [endpoint(path: "/api/v1/posts/{slug}/revisions")])

      outcome = result.outcomes.first
      expect(outcome.reason).to eq(:path_params_unresolved)
      expect(outcome.detail).to include("{slug}")
    end

    it "uses seeded ids when they exist" do
      config.scale_factors = [10]
      config.page_size_sweep = [5]
      config.requests_per_endpoint_per_level = 1
      config.warmup_requests = 0
      resolver = Loadwright::Discovery::PathParamResolver.new(config: config, seeded_ids: { "post" => [7, 8] })
      transport = Loadwright::Execution::Transport::Null.new(config: config)
      context = Loadwright::Execution::ExecutionContext.new(
        config: config, transport: transport,
        collector: ExecutionHelpers::ScriptedCollector.new(config: config)
      )

      runner(context: context, resolver: resolver).run(endpoints: [endpoint(path: "/api/v1/posts/{id}")])

      expect(transport.issued.map(&:path).uniq).to all(match(%r{/api/v1/posts/[78]}))
    end
  end

  # REGRESSION: a clean endpoint must not be reported as having no coverage.
  #
  # The bug this guards against, in full, because the shape of it is the point and a
  # future "simplification" would reintroduce it in one line:
  #
  # Over-fetch coverage needs the set of tables the endpoint queried. That set was
  # sourced from the DUPLICATE query fingerprints — the same structure the N+1
  # pattern-match detector reads. But a clean endpoint has NO duplicate fingerprints by
  # definition. So a healthy endpoint looked as though it had queried no tables at all,
  # over-fetch came back uncovered, and the endpoint went `inconclusive`.
  #
  # The healthiest endpoints in an API would have been the ones reported as unmeasurable
  # — an inverted signal, which is precisely the failure the three-state model exists to
  # prevent. Tables are recorded from EVERY query, not just the repeated ones.
  #
  # WHICH ASSERTION BELOW IS LOAD-BEARING: the coverage one. Over-fetch later became
  # an ADVISORY class, which independently stops an over-fetch gap escalating to
  # `inconclusive` — so reintroducing this bug today corrupts the reported coverage
  # without changing the state. Verified by reintroducing it: only `be_covered` fails.
  # The healthy expectation is kept as documentation of the original harm, but the
  # coverage expectation is what would catch a regression now.
  describe "over-fetch coverage on an endpoint with no duplicate queries" do
    before do
      config.scale_factors = [10, 100]
      config.page_size_sweep = [5]
      config.requests_per_endpoint_per_level = 2
      config.warmup_requests = 0
    end

    # Distinct fingerprints only: nothing repeats, so `duplicates` stays empty while
    # three real tables were queried.
    def clean_metrics
      Loadwright::Execution::RequestMetrics.new(
        request_id: "r", collector: :direct,
        queries: [
          { fingerprint: 'SELECT "posts".* FROM "posts" WHERE "posts"."id" = ?' },
          { fingerprint: 'SELECT "authors".* FROM "authors" WHERE "authors"."id" = ?' },
          { fingerprint: 'SELECT COUNT(*) FROM "comments" WHERE "comments"."post_id" = ?' }
        ],
        query_count: Loadwright::Measurement.value(3),
        distinct_query_count: Loadwright::Measurement.value(3)
      )
    end

    let(:result) do
      responder = ->(_) { { status: 200, body: JSON.generate([{ "id" => 1 }]) } }
      context = build_context(responder: responder, metrics: clean_metrics)
      config.requests_per_endpoint_per_level = 20

      runner(context: context).run(endpoints: [endpoint])
    end

    it "records every queried table, not only the repeated ones" do
      cell = result.cells_for("GET /api/v1/posts").find { |c| c.sweep == :seed_scale }

      expect(cell.duplicates).to be_empty, "premise: this endpoint has no duplicate fingerprints"
      expect(cell.tables).to contain_exactly("posts", "authors", "comments")
    end

    it "covers the over-fetch class rather than reporting it unanswered" do
      coverage = result.outcomes.first.coverage

      expect(coverage).to be_covered(:over_fetch)
      expect(coverage).not_to be_unanswered(:over_fetch)
    end

    # The consequence, stated as its own expectation so the failure names the harm.
    it "reports the clean endpoint as healthy, NOT as inconclusive" do
      outcome = result.outcomes.first

      expect(outcome).to be_healthy,
                         "a clean endpoint was reported #{outcome.state} " \
                         "(#{outcome.detail}) — the inverted-signal regression is back"
    end
  end

  # The run-level pattern has to reach the per-endpoint verdict, or the user still gets
  # a report full of `inconclusive` with the explanation sitting somewhere else.
  describe "a run where the identity is refused everywhere" do
    let(:result) do
      config.scale_factors = [10]
      config.page_size_sweep = [5]
      config.requests_per_endpoint_per_level = 5
      config.warmup_requests = 0
      responder = ->(_) { { status: 403, body: '{"error":"forbidden"}' } }

      runner(context: build_context(responder: responder)).run(
        endpoints: [endpoint, endpoint(path: "/api/v1/authors"), endpoint(path: "/api/v1/comments")]
      )
    end

    it "diagnoses the token rather than reporting three unexplained failures" do
      expect(result.traffic.map(&:kind)).to eq([:auth_misconfigured])
    end

    it "gives each endpoint the reason that names the fix" do
      expect(result.outcomes.map(&:reason).uniq).to eq([:auth_failed])
      expect(result.outcomes.first.explanation).to include("auth_token_provider")
    end

    it "prints the diagnosis during the run, not only into the report" do
      result

      expect(stdout.string).to include("returned only 401/403")
    end

    it "carries the diagnosis into run metadata" do
      expect(result.metadata[:traffic].first[:kind]).to eq(:auth_misconfigured)
    end
  end

  # `ensure` does not run on a signal, and the partial record is what the next run gets
  # compared against -- and what the partial-report path reads from.
  describe "run history" do
    require "tmpdir"

    around { |example| Dir.mktmpdir("engine-history-") { |dir| @dir = dir; example.run } }

    before do
      config.run_history_dir = @dir
      config.scale_factors = [10]
      config.page_size_sweep = [5]
      config.requests_per_endpoint_per_level = 2
      config.warmup_requests = 0
    end

    let(:lifecycle) { Loadwright::Lifecycle.new(stderr: StringIO.new) }
    let(:store) { Loadwright::History::RunStore.new(config: config, lifecycle: lifecycle) }

    # The runner persists its OWN result. "An interrupted run still leaves a usable
    # record" cannot depend on the caller remembering to write one -- the interrupted
    # caller is exactly the one that did not get that far.
    it "leaves a usable record when the run is interrupted partway" do
      calls = 0
      responder = lambda do |_|
        calls += 1
        raise Loadwright::Interrupted, "ctrl-c" if calls > 2

        { status: 200, body: '[{"id":1}]' }
      end

      runner(context: build_context(responder: responder), run_store: store, lifecycle: lifecycle)
        .run(endpoints: [endpoint])
      lifecycle.run_teardown!

      expect(store.list.length).to eq(1)
      expect(store.latest.metadata["aborted"]).to be(true)
      expect(store.latest.endpoints).not_to be_empty
    end

    # The armed hook covers the one case the runner cannot: #run never returning,
    # because something it does not handle escaped. A transport turns a responder's
    # exception into an errored response by design, so this raises from the RESOLVER,
    # which sits outside that rescue.
    it "still leaves a record when the run raises something it does not handle" do
      resolver = Object.new
      calls = 0
      # Late enough that the first cell has already been recorded -- the hook
      # deliberately writes nothing when a run dies before collecting anything, since
      # an empty record would later read as a run that found nothing.
      resolver.define_singleton_method(:resolve) do |_endpoint|
        calls += 1
        raise "the database went away" if calls > 4

        nil
      end
      resolver.define_singleton_method(:seeded_ids=) { |_| nil }

      expect do
        runner(context: build_context(responder: ->(_) { { status: 200, body: "[]" } }),
               run_store: store, lifecycle: lifecycle, resolver: resolver).run(endpoints: [endpoint])
      end.to raise_error(/database went away/)
      lifecycle.run_teardown!

      expect(store.list.length).to eq(1)
      expect(store.latest.metadata["aborted"]).to be(true)
    end

    # A COMPLETED RUN MUST NOT ALSO WRITE AN "INTERRUPTED" RECORD. The armed teardown
    # fires on every Lifecycle teardown, including the ordinary one at the end of a
    # successful run -- so without this it wrote a second record per run, marked
    # aborted. Those then appeared in `runs list` and made every comparison warn that
    # a perfectly healthy run had been aborted partway.
    it "writes exactly one record for a run that finished" do
      responder = ->(_) { { status: 200, body: '[{"id":1}]' } }
      runner(context: build_context(responder: responder), run_store: store, lifecycle: lifecycle)
        .run(endpoints: [endpoint])
      lifecycle.run_teardown!

      expect(store.list.length).to eq(1)
    end

    it "does not mark a completed run aborted" do
      responder = ->(_) { { status: 200, body: '[{"id":1}]' } }
      runner(context: build_context(responder: responder), run_store: store,
             lifecycle: lifecycle).run(endpoints: [endpoint])
      lifecycle.run_teardown!

      expect(store.list.map { |record| record.metadata["aborted"] }).to all(be(false))
    end

    # A dry run issues no requests. A record of one would be a run of zeroes sitting in
    # history waiting to be compared against something real.
    it "persists nothing for a dry run" do
      context = Loadwright::Execution::ExecutionContext.new(
        config: config,
        transport: Loadwright::Execution::Transport::Null.new(config: config, dry_run: true),
        collector: ExecutionHelpers::ScriptedCollector.new(config: config, name: :direct)
      )
      runner(context: context, run_store: store, lifecycle: lifecycle).run(endpoints: [endpoint])

      expect(store.list).to be_empty
    end

    # An empty record would later read as a run that found nothing, which is a different
    # claim from a run that never got going.
    it "writes nothing when the interrupt landed before any cell ran" do
      runner(context: build_context, run_store: store, lifecycle: lifecycle)
      lifecycle.run_teardown!

      expect(store.list).to be_empty
    end
  end

  describe "the RunResult data shape" do
    it "separates the three states rather than collapsing them" do
      responder = lambda do |request|
        request.path.include?("admin") ? { status: 403, body: "{}" } : { status: 200, body: '[{"id":1}]' }
      end
      config.scale_factors = [10]
      config.page_size_sweep = [5]
      config.requests_per_endpoint_per_level = 20
      config.warmup_requests = 0

      result = runner(context: build_context(responder: responder))
               .run(endpoints: [endpoint, endpoint(path: "/api/v1/admin/stats")])

      expect(result.summary).to include(endpoints: 2, inconclusive: 1)
      # "clean" means healthy, never "not has_findings" — 18 endpoints clean is a lie
      # if 12 of them were inconclusive.
      expect(result.clean.length + result.inconclusive.length + result.with_findings.length).to eq(2)
    end

    it "carries the auditable metadata a report needs without the scrollback" do
      metadata = runner.run(endpoints: [endpoint]).metadata

      expect(metadata).to include(:loadwright_version, :execution_mode, :transport, :collector,
                                  :capabilities, :config_fingerprint, :config)
      expect(metadata[:transport]).to eq(:null)
    end

    it "serialises to a plain hash" do
      serialised = runner.run(endpoints: [endpoint]).to_h

      expect(serialised.keys).to contain_exactly(:metadata, :summary, :endpoints, :cells)
      expect { JSON.generate(serialised) }.not_to raise_error
    end
  end
end

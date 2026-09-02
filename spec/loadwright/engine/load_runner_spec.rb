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

    # THE DRY RUN IS WHERE A CONFIGURATION PROBLEM SHOULD SURFACE. The page-size sweep
    # correctly refuses to run against too little data, and refusing is right -- but
    # it means one of the two N+1 detectors did not execute, and finding that out
    # after a completed run is late.
    describe "when the page-size sweep will not be able to run" do
      def dry_run_output
        config.scale_factors = [1, 10]
        config.page_size_sweep = [5, 25, 100]
        transport = Loadwright::Execution::Transport::Null.new(config: config, dry_run: true)
        context = Loadwright::Execution::ExecutionContext.new(
          config: config, transport: transport,
          collector: ExecutionHelpers::ScriptedCollector.new(config: config)
        )
        runner(context: context).run(endpoints: [endpoint])
        stdout.string
      end

      it "says so before the run, not after it" do
        expect(dry_run_output).to include("the page-size sweep will NOT run")
      end

      it "says what that costs, so a healthy verdict is read with it in mind" do
        expect(dry_run_output).to include("one of the two N+1 detectors")
      end

      it "stays quiet when the sweep can run" do
        config.scale_factors = [1, 200]
        config.page_size_sweep = [5, 25, 100]
        transport = Loadwright::Execution::Transport::Null.new(config: config, dry_run: true)
        context = Loadwright::Execution::ExecutionContext.new(
          config: config, transport: transport,
          collector: ExecutionHelpers::ScriptedCollector.new(config: config)
        )

        runner(context: context).run(endpoints: [endpoint])

        expect(stdout.string).not_to include("page-size sweep will NOT run")
      end
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

  # require_schema_valid_response defaults to true, and the check produced no output
  # anywhere -- neither in the checked half of the coverage line nor in the not-checked
  # half. A reader could not tell a validated response from one that was never
  # validated because the operation declares no schema, which is exactly the
  # distinction the setting exists to make.
  describe "whether the response was checked against its declared schema" do
    before do
      config.scale_factors = [10]
      config.page_size_sweep = [5]
      config.concurrency_levels = [1]
      config.requests_per_endpoint_per_level = 20
      config.warmup_requests = 0
    end

    let(:document) do
      { "components" => { "schemas" => { "Widget" => { "type" => "array" } } } }
    end

    let(:schema) do
      Loadwright::Discovery::SchemaRef.for(document: document, pointer: "#/components/schemas/Widget")
    end

    let(:responder) { ->(_) { { status: 200, body: JSON.generate(Array.new(5) { { "id" => 1 } }) } } }

    it "reports a schema that was checked and matched" do
      documented = endpoint(response_schemas: { 200 => schema })
      result = runner(context: build_context(responder: responder, metrics: { query_count: 2 }))
               .run(endpoints: [documented])

      expect(result.schema_validation[documented.to_s][:state]).to eq(:validated)
    end

    # TWO DIFFERENT FACTS, AND ONLY ONE IS ABOUT THE USER'S API. Sharing one sentence
    # is how a join defect -- the server base path being ignored -- got reported for a
    # whole API as "none declared", pointing the reader at documents that declared a
    # schema for 50 of their 61 operations.
    it "says a matched operation declares no schema, when a document did match" do
      documented = endpoint(response_schemas: {})
      result = runner(context: build_context(responder: responder, metrics: { query_count: 2 }))
               .run(endpoints: [documented])

      disclosure = result.schema_validation[documented.to_s]
      expect(disclosure[:state]).to eq(:no_schema)
      expect(disclosure[:note]).to include("declares no 2xx response schema")
    end

    # The common case on an app discovering from recordings, and the one that looked
    # identical to a pass. A recording cannot supply a response schema; only a
    # document can.
    it "says no document operation matched, when none did, and names the sources" do
      recorded = Loadwright::Discovery::Endpoint.new(path: "/api/v1/posts", verb: :get,
                                                     source: :integration_spec)
      result = runner(context: build_context(responder: responder, metrics: { query_count: 2 }))
               .run(endpoints: [recorded])

      disclosure = result.schema_validation[recorded.to_s]
      expect(disclosure[:state]).to eq(:no_document_match)
      expect(disclosure[:note]).to include("no OpenAPI operation matched")
      expect(disclosure[:note]).to include("integration_spec")
    end

    # Recorded for EVERY exercised endpoint, not only the ones that came back clean.
    # An inconclusive endpoint is where a reader most wants to know whether the schema
    # was consulted.
    it "records the disclosure even when the endpoint came back inconclusive" do
      forbidden = ->(_) { { status: 403, body: "{}" } }
      result = runner(context: build_context(responder: forbidden)).run(endpoints: [endpoint])

      expect(result.outcomes.first).to be_inconclusive
      expect(result.schema_validation[endpoint.to_s]).not_to be_nil
    end
  end

  # A REQUEST THAT ISSUED ZERO QUERIES NEVER REACHED THE DATA LAYER.
  #
  # So no factory, trait, `param:` or scale factor can change its outcome. The number
  # that proves it has been in the cell table since the first run -- and an
  # integration still spent four rounds recommending a factory fix for fifteen
  # endpoints whose own rows read zero queries, because nothing in the report ever
  # objected to a remedy its own data ruled out.
  describe "a 5xx that never reached the database" do
    before do
      config.scale_factors = [10]
      config.page_size_sweep = [5]
      config.concurrency_levels = [1]
      config.requests_per_endpoint_per_level = 20
      config.warmup_requests = 0
    end

    def run_with(responder, metrics: { query_count: 0 })
      runner(context: build_context(responder: responder, metrics: metrics)).run(endpoints: [endpoint])
    end

    it "says seeding cannot be the remedy" do
      outcome = run_with(->(_) { { status: 500, body: "boom" } }).outcomes.first

      expect(outcome).to be_inconclusive
      expect(outcome.detail).to include("ZERO queries")
      expect(outcome.detail).to include("seeding is not the remedy")
    end

    # The claim is about reaching the data layer, so one query is enough to withdraw
    # it. Saying "seeding cannot help" about an endpoint that did query would be the
    # same species of confident wrongness one direction over.
    it "says nothing of the sort when the endpoint did query" do
      outcome = run_with(->(_) { { status: 500, body: "boom" } }, metrics: { query_count: 3 }).outcomes.first

      expect(outcome.detail.to_s).not_to include("ZERO queries")
    end

    # THE EXCEPTION STANDS ON ITS OWN. It used to be printed only as part of the
    # zero-query sentence, so an endpoint that DID reach the database and then raised --
    # which is most 500s, and every one that renders a framework error page -- named
    # nothing at all. A quarantined endpoint is precisely the one whose cause nobody
    # has.
    it "names the exception even when the endpoint reached the database first" do
      responder = lambda do |_|
        { status: 500, body: "<html>error</html>",
          app_exception: { class: "Widgets::CalculationError", frame: "/app/models/widget.rb:41" } }
      end
      outcome = run_with(responder, metrics: { query_count: 7 }).outcomes.first

      expect(outcome.detail).to include("Widgets::CalculationError")
      expect(outcome.detail).to include("widget.rb:41")
      expect(outcome.detail.to_s).not_to include("ZERO queries")
    end

    # ONLY WE CAN SEE THIS ONE. The block is ours and invisible to the user, so a
    # containment false positive is indistinguishable from a broken endpoint.
    it "says when our own containment caused the failure" do
      responder = lambda do |_|
        { status: 500, body: "{}",
          app_exception: { class: "Client::RequestFailure", frame: "/app/lib/client.rb:75",
                           containment: "blocked by config.block_outbound_http: keys.example.test" } }
      end
      outcome = run_with(responder).outcomes.first

      expect(outcome.detail).to include("block_outbound_http")
      expect(outcome.detail).to include("keys.example.test")
    end

    # A 404 with no queries is an ordinary routing or scope answer, not a failure
    # ahead of the data layer worth this sentence.
    it "is reserved for 5xx, not for any non-2xx" do
      outcome = run_with(->(_) { { status: 404, body: "{}" } }).outcomes.first

      expect(outcome.detail.to_s).not_to include("ZERO queries")
    end
  end

  # PROVENANCE ALONE ANSWERS "IS THIS 404 OURS OR THEIRS". It does not answer "what
  # did you actually ask it", and the second question decides what a finding MEANS: an
  # endpoint taking a `view` parameter can issue 3 queries at its default and 147 at
  # another value, so a repeat count with no mention of the value is a property of one
  # parameterisation reported as a property of the endpoint.
  describe "the values a request actually sent" do
    before do
      config.scale_factors = [10]
      config.page_size_sweep = [25]
      config.concurrency_levels = [1]
      config.requests_per_endpoint_per_level = 20
      config.warmup_requests = 0
      config.replay_recorded_query_params = true
    end

    let(:with_view) { endpoint(query_params: [{ name: "view", example: "detailed" }]) }

    it "records each parameter's value alongside where it came from" do
      result = runner(context: build_context(responder: ->(_) { { status: 200, body: "[]" } }))
               .run(endpoints: [with_view])

      sent = result.request_shapes[with_view.to_s][:query]["view"]
      expect(sent[:value]).to eq("detailed")
      expect(sent[:source]).to eq(:recorded)
    end

    # The shape recorded is the SEED-SCALE one, which by design sends no page size --
    # the page-size sweep varies exactly that one parameter and the cell table names
    # every value it used, so the two together describe every request made.
    it "shows the shape the endpoint is measured as clients call it" do
      result = runner(context: build_context(responder: ->(_) { { status: 200, body: "[]" } }))
               .run(endpoints: [with_view])

      expect(result.request_shapes[with_view.to_s][:query])
        .not_to have_key(config.page_size_parameters.first)
    end
  end

  # "THE SEEDED RECORDS DID NOT MATCH THIS ENDPOINT'S SCOPE" is true and leaves the
  # reader to find the scope themselves. The filter columns of the query that returned
  # nothing are the actionable half, and Rails has been carrying the row count on the
  # notification all along -- nothing read it.
  describe "an endpoint whose query found no rows" do
    before do
      config.scale_factors = [10]
      config.page_size_sweep = [5]
      config.concurrency_levels = [1]
      config.requests_per_endpoint_per_level = 20
      config.warmup_requests = 0
    end

    let(:empty_lookup) do
      { query_count: 2,
        queries: [{ fingerprint: "SELECT * FROM widgets WHERE widgets.status = ? AND widgets.owner_id = ?",
                    row_count: 0 },
                  { fingerprint: "SELECT * FROM accounts WHERE accounts.id = ?", row_count: 1 }] }
    end

    it "names the table and the columns that excluded the data" do
      outcome = runner(context: build_context(responder: ->(_) { { status: 404, body: "{}" } },
                                              metrics: empty_lookup))
                .run(endpoints: [endpoint]).outcomes.first

      expect(outcome.detail).to include("widgets filtered on")
      expect(outcome.detail).to include("status")
      expect(outcome.detail).to include("factory trait")
    end

    # A query that DID find rows is not the one that excluded the data, and naming it
    # would send someone to change a scope that is working.
    it "names only the queries that returned nothing" do
      outcome = runner(context: build_context(responder: ->(_) { { status: 404, body: "{}" } },
                                              metrics: empty_lookup))
                .run(endpoints: [endpoint]).outcomes.first

      expect(outcome.detail).not_to include("accounts")
    end

    # SQL KEYWORDS AND TABLE NAMES ARE NOT COLUMNS. `IN` with no word boundary matched
    # inside DISTINCT and JOIN, so the first version emitted `DIST` and `JO` as column
    # names and truncated real identifiers mid-word -- one to a single character
    # matching three columns on its own table.
    it "names no SQL keyword, and no truncated fragment" do
      joined = "SELECT DISTINCT widgets.* FROM widgets INNER JOIN accounts " \
               "ON accounts.id = widgets.owner_id WHERE widgets.owner_type = ? AND widgets.removed_at IS NULL"
      outcome = runner(context: build_context(responder: ->(_) { { status: 404, body: "{}" } },
                                              metrics: { query_count: 1,
                                                         queries: [{ fingerprint: joined, row_count: 0 }] }))
                .run(endpoints: [endpoint]).outcomes.first

      expect(outcome.detail).to include("owner_type", "removed_at")
      expect(outcome.detail).not_to include("DIST")
      expect(outcome.detail).not_to include("JO,")
    end

    # A JOIN's ON keys are join STRUCTURE, not the filter that excluded the rows, and
    # naming them sends someone to change an association that is working.
    it "reads the WHERE clause only, not the join keys or the select list" do
      joined = "SELECT widgets.* FROM widgets INNER JOIN accounts ON accounts.id = widgets.owner_id " \
               "WHERE widgets.status = ? ORDER BY widgets.id LIMIT ?"
      outcome = runner(context: build_context(responder: ->(_) { { status: 404, body: "{}" } },
                                              metrics: { query_count: 1,
                                                         queries: [{ fingerprint: joined, row_count: 0 }] }))
                .run(endpoints: [endpoint]).outcomes.first

      expect(outcome.detail).to include("status")
      expect(outcome.detail).not_to include("owner_id")
    end

    # ABSENT, NEVER ZERO. An adapter or Rails version that does not report row counts
    # must not be read as "every query found nothing".
    it "says nothing when the row count was never reported" do
      metrics = { query_count: 2,
                  queries: [{ fingerprint: "SELECT * FROM widgets WHERE widgets.status = ?" }] }
      outcome = runner(context: build_context(responder: ->(_) { { status: 404, body: "{}" } },
                                              metrics: metrics))
                .run(endpoints: [endpoint]).outcomes.first

      expect(outcome.detail.to_s).not_to include("No rows came back")
    end
  end

  # A SCHEMA WE COULD NOT LOAD IS NOT A RESPONSE THAT FAILED, and the difference is not
  # cosmetic: a schema violation disqualifies an endpoint, and a disqualified endpoint
  # keeps none of its findings. So a one-line escaping fault inside this gem reported
  # twenty endpoints as having invalid responses AND discarded three N+1 findings it
  # had already measured correctly.
  describe "a declared schema Loadwright cannot load" do
    before do
      config.scale_factors = [10]
      config.page_size_sweep = [5]
      config.concurrency_levels = [1]
      config.requests_per_endpoint_per_level = 20
      config.warmup_requests = 0
    end

    # A pointer into a document that does not contain it: resolution fails the way a
    # malformed one does, without depending on the specific malformation.
    let(:broken) do
      Loadwright::Discovery::SchemaRef.new(document: { "paths" => {} },
                                           pointer: "#/paths/~1gone/get/schema")
    end

    let(:documented) { endpoint(response_schemas: { 200 => broken }) }

    let(:n_plus_one) do
      { query_count: 9,
        queries: Array.new(9) { { fingerprint: "SELECT * FROM widgets WHERE id = ?" } } }
    end

    def run_it
      runner(context: build_context(responder: ->(_) { { status: 200, body: '[{"id":1}]' } },
                                    metrics: n_plus_one)).run(endpoints: [documented])
    end

    it "does not report the response as having failed validation" do
      outcome = run_it.outcomes.first

      expect(outcome.reason).not_to eq(:schema_invalid)
    end

    it "keeps the findings it measured before the schema was ever consulted" do
      outcome = run_it.outcomes.first

      expect(outcome.findings.map(&:kind)).to include(:n_plus_one_pattern_match)
    end

    # OURS, AND SAID SO. The reader must not go looking at their document or their
    # responses for something neither of them caused.
    it "discloses it as a Loadwright fault, naming nothing about the response" do
      disclosure = run_it.schema_validation[documented.to_s]

      expect(disclosure[:state]).to eq(:unresolvable)
      expect(disclosure[:note]).to include("fault in Loadwright")
      expect(disclosure[:note]).not_to include("did not validate")
    end

    # The distinction has to survive: a response that genuinely fails a schema it
    # COULD load is still invalid, and still disqualifies the endpoint.
    it "still invalidates a response that fails a schema it could load" do
      schema = Loadwright::Discovery::SchemaRef.for(
        document: { "s" => { "type" => "object", "required" => %w[missing] } }, pointer: "#/s"
      )
      outcome = runner(context: build_context(responder: ->(_) { { status: 200, body: '{"id":1}' } },
                                              metrics: { query_count: 2 }))
                .run(endpoints: [endpoint(response_schemas: { 200 => schema })]).outcomes.first

      expect(outcome.reason).to eq(:schema_invalid)
    end
  end

  # THE SETTING PROMISES THE CACHE IS OFF AND IT IS NOT: Rails' own QueryCache
  # middleware enables it per request, after our setup-time disable.
  #
  # What that does and does not affect is the whole point of the sentence, and the
  # first version of this warning got it backwards. Counts are LOGICAL -- the tracker
  # records every query the code issued, hit or not -- so the N+1 threshold applies to
  # how many times the code asked and nothing is undercounted. Latency is what a live
  # cache changes.
  describe "when disable_query_cache_during_run did not hold" do
    before do
      config.scale_factors = [10]
      config.page_size_sweep = [5]
      config.concurrency_levels = [1]
      config.requests_per_endpoint_per_level = 20
      config.warmup_requests = 0
    end

    let(:cached_metrics) do
      { query_count: 4,
        queries: [{ fingerprint: "SELECT 1", cached: false }, { fingerprint: "SELECT 1", cached: true }] }
    end

    it "says so on the run, where the reader can see it" do
      result = runner(context: build_context(responder: ->(_) { { status: 200, body: "[]" } },
                                             metrics: cached_metrics)).run(endpoints: [endpoint])

      expect(result.warnings.join).to include("disable_query_cache_during_run")
      expect(result.warnings.join).to include("did not take effect")
    end

    # THE SENTENCE HAS TO BE RIGHT, not merely present. Telling someone their N+1
    # counts are undercounted when they are not sends them to re-run at a lower
    # threshold chasing findings that were never missing.
    it "says plainly that counts are unaffected, and that latency is not" do
      result = runner(context: build_context(responder: ->(_) { { status: 200, body: "[]" } },
                                             metrics: cached_metrics)).run(endpoints: [endpoint])

      expect(result.warnings.join).to include("counts are UNAFFECTED")
      expect(result.warnings.join).to include("latency")
    end

    # The count the threshold sees is what the code ASKED for: two executed plus three
    # served from the cache is a repeat of five, and clears a threshold of three.
    it "counts a cache hit toward the repeat count, so no finding is missed" do
      mixed = { query_count: 5,
                queries: Array.new(2) { { fingerprint: "SELECT 1", cached: false } } +
                         Array.new(3) { { fingerprint: "SELECT 1", cached: true } } }
      result = runner(context: build_context(responder: ->(_) { { status: 200, body: '[{"id":1}]' } },
                                             metrics: mixed)).run(endpoints: [endpoint])

      finding = result.outcomes.first.findings.find { |f| f.kind == :n_plus_one_pattern_match }
      expect(finding).not_to be_nil
      expect(finding.detail).to include("ran 5 times in a single request")
    end

    # The warning is about a promise not kept. With the setting off there is no
    # promise, and a cache hit is expected rather than notable.
    it "says nothing when the cache was never asked to be disabled" do
      config.disable_query_cache_during_run = false
      result = runner(context: build_context(responder: ->(_) { { status: 200, body: "[]" } },
                                             metrics: cached_metrics)).run(endpoints: [endpoint])

      expect(result.warnings.join).not_to include("disable_query_cache_during_run")
    end

    it "says nothing when no cached query ever arrived" do
      result = runner(context: build_context(responder: ->(_) { { status: 200, body: "[]" } },
                                             metrics: { query_count: 2 })).run(endpoints: [endpoint])

      expect(result.warnings.join).not_to include("disable_query_cache_during_run")
    end
  end

  # A FINDING MEASURED ON A RESPONSE THAT DID THE WORK SURVIVES A DISQUALIFICATION ON A
  # DIFFERENT AXIS.
  #
  # The validity gate exists so no performance verdict attaches to a response that did
  # not prove it did the work -- the round-5 healthy-404 rule, not being loosened. But
  # "did not do the work" and "did the work and does not match its documentation" are
  # different sentences, and only the first justifies discarding measurements.
  #
  # Discarding them there cost one integration TWO CONSECUTIVE ROUNDS of a
  # high-confidence N+1 the tool had reported correctly in the eight rounds before, on
  # an endpoint that answered 200 six hundred times. Silence is indistinguishable from
  # health to a reader who was not there for those rounds.
  describe "an endpoint disqualified by its schema after the work was measured" do
    before do
      config.scale_factors = [10]
      config.page_size_sweep = [5]
      config.concurrency_levels = [1]
      config.requests_per_endpoint_per_level = 20
      config.warmup_requests = 0
    end

    let(:violating) do
      schema = Loadwright::Discovery::SchemaRef.for(
        document: { "s" => { "type" => "object", "required" => %w[absent] } }, pointer: "#/s"
      )
      endpoint(response_schemas: { 200 => schema })
    end

    let(:n_plus_one) do
      { query_count: 12,
        queries: Array.new(12) { { fingerprint: "SELECT * FROM widgets WHERE id = ?" } } }
    end

    def run_it(ep = violating, metrics: n_plus_one, body: '[{"id":1}]')
      runner(context: build_context(responder: ->(_) { { status: 200, body: body } }, metrics: metrics))
        .run(endpoints: [ep])
    end

    it "still reports the endpoint as inconclusive, because coverage really is incomplete" do
      outcome = run_it.outcomes.first

      expect(outcome).to be_inconclusive
      expect(outcome.reason).to eq(:schema_invalid)
    end

    it "keeps the finding it measured rather than discarding it" do
      outcome = run_it.outcomes.first

      expect(outcome.retained_findings.map(&:kind)).to include(:n_plus_one_pattern_match)
      expect(outcome.retained_findings.first.detail).to include("ran 12 times in a single request")
    end

    # Three states stay load-bearing. A retained finding is evidence, not a verdict, and
    # counting it as one would make `has_findings` mean two different things.
    it "does not count as an endpoint with findings" do
      result = run_it

      expect(result.with_findings).to be_empty
      expect(result.summary[:has_findings]).to eq(0)
      expect(result.summary[:inconclusive]).to eq(1)
    end

    # THE ROUND-5 RULE, UNTOUCHED. An error status means the response never proved it
    # did the work, so its findings describe an error path and are correctly discarded.
    it "discards findings measured on an endpoint that failed its status check" do
      outcome = run_it(endpoint, body: "boom",
                       metrics: n_plus_one).outcomes.first
      erroring = runner(context: build_context(responder: ->(_) { { status: 500, body: "boom" } },
                                               metrics: n_plus_one)).run(endpoints: [endpoint]).outcomes.first

      expect(outcome).not_to be_nil
      expect(erroring).to be_inconclusive
      expect(erroring.retained_findings).to be_empty
    end

    it "renders them under a heading that is not a verdict" do
      text = Loadwright::Reporting::MarkdownReport.new(config: config).render(run_it)

      expect(text).to include("Measured before this endpoint was set aside")
      expect(text).to include("n_plus_one_pattern_match")
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
  # WHAT A PASSING SPEC ACTUALLY SENT. Discovery collects the recorded query
  # parameters and headers, and the run used to send neither -- so an endpoint whose
  # spec sends an Accept header answered 406 on every request, and one with a required
  # query parameter answered 400. Both were correctly marked inconclusive, and both
  # were coverage lost to the reconstruction rather than to anything about the app,
  # with everything needed to build a valid request sitting in a file we wrote.
  describe "rebuilding a request from what was recorded" do
    def request_for(endpoint, page_size: nil)
      runner.send(:build_request, endpoint, nil, page_size)
    end

    let(:recorded) do
      endpoint(
        query_params: [{ name: "view", example: "summary" }],
        recorded_headers: { "Accept" => "application/vnd.api+json", "Host" => "example.test" }
      )
    end

    it "sends the query parameters the recording holds" do
      expect(request_for(recorded).query).to include("view" => "summary")
    end

    it "sends a recorded header that is on the replay list" do
      expect(request_for(recorded).headers).to include("Accept" => "application/vnd.api+json")
    end

    # By name, not wholesale: a recording holds the whole relevant header set, and
    # replaying somebody's Host would be wrong.
    it "does not send a recorded header that is not on the list" do
      expect(request_for(recorded).headers).not_to have_key("Host")
    end

    # Replaying a recorded per_page would pin the axis the page-size sweep exists to
    # vary, and the flat line that produced would read as healthy.
    it "drops a recorded page-size parameter rather than pinning the sweep" do
      pinned = endpoint(query_params: [{ name: "per_page", example: "25" }])

      expect(request_for(pinned).query).to be_empty
      expect(request_for(pinned, page_size: 100).query).to eq("per_page" => 100)
    end

    # AN IDENTIFIER IN A QUERY STRING IS STILL AN IDENTIFIER. A recorded id in the
    # PATH is the weakest evidence in a four-source chain, behind an override and a
    # seeded row, because a spec's ids do not exist in the database being measured.
    # The same id in a query string was replayed as fact -- so a spec placeholder went
    # out verbatim, matched nothing, and the endpoint answered 404 as though it were
    # the broken one.
    describe "a recorded query parameter that looks like an identifier" do
      let(:with_id) { endpoint(query_params: [{ name: "warehouse_id", example: "spec-placeholder" }]) }

      def resolver_with(seeded)
        Loadwright::Discovery::PathParamResolver.new(config: config, seeded_ids: seeded)
      end

      it "prefers a seeded value over the one the spec happened to send" do
        run = runner(resolver: resolver_with("warehouse" => [41, 42]))

        expect(run.send(:build_request, with_id, nil, nil).query).to eq("warehouse_id" => 41)
      end

      it "still sends the recorded value when nothing seeded can resolve it" do
        run = runner(resolver: resolver_with({}))

        expect(run.send(:build_request, with_id, nil, nil).query).to eq("warehouse_id" => "spec-placeholder")
      end

      # An ordinary filter is not an identifier, and replaying it is exactly right.
      it "leaves a parameter that is not identifier-shaped alone" do
        filtered = endpoint(query_params: [{ name: "view", example: "summary" }])
        run = runner(resolver: resolver_with("warehouse" => [41]))

        expect(run.send(:build_request, filtered, nil, nil).query).to eq("view" => "summary")
      end
    end

    it "sends nothing recorded when the replay is switched off" do
      config.replay_recorded_query_params = false
      config.replay_recorded_headers = []

      expect(request_for(recorded).query).to be_empty
      expect(request_for(recorded).headers).to be_empty
    end
  end
  # THE WORST SINGLE REQUEST, ACROSS CELLS. `absorb` gets this right within one cell
  # and the merge across cells concatenated, so the reported repeat count was a sum
  # over every cell -- a property of the reader's CONFIGURATION rather than of their
  # endpoint. Raising scale_factors, which the tool itself recommends, tripled every
  # N+1 severity in the report with no change to the application.
  describe "how many times a query ran in a single request" do
    def finding_for(scale_factors)
      config.scale_factors = scale_factors
      config.requests_per_endpoint_per_level = 2
      sql = 'SELECT "warehouses".* FROM "warehouses" WHERE "warehouses"."id" = ?'
      # Four occurrences in EVERY request of EVERY cell. However many cells there are,
      # the answer to "how many times in a single request" is four.
      metrics = { queries: Array.new(4) { { fingerprint: sql } }, query_count: 8 }
      # A non-empty body, so the validity gate does not stop the endpoint short of a
      # performance verdict -- the seeded-data-but-empty-collection rule would fire
      # at the larger scale factors and there would be no finding to inspect.
      responder = ->(_request) { { status: 200, body: JSON.generate([{ "id" => 1 }]) } }

      context = build_context(metrics: metrics, responder: responder)
      result = runner(context: context).run(endpoints: [endpoint])
      result.outcomes.first.findings.find { |f| f.kind == :n_plus_one_pattern_match }
    end

    it "reports the per-request count, not a sum across cells" do
      expect(finding_for([1, 10]).evidence[:occurrences]).to eq(4)
    end

    it "does not change when more cells are configured" do
      expect(finding_for([1, 10, 100]).evidence[:occurrences]).to eq(finding_for([1, 10]).evidence[:occurrences])
    end

    # THE INVARIANT, and it is the cheap regression test this bug deserved. A request
    # that issues eight queries cannot issue one of them twelve times. The report used
    # to state both, on the same page.
    it "never claims a query repeated more often than the endpoint issued queries" do
      finding = finding_for([1, 10, 100])

      expect(finding.evidence[:occurrences]).to be <= 8
    end
  end
  # "THIS ENDPOINT 404s" AND "THIS ENDPOINT 404s WITH PARAMETERS WE REPLAYED FROM A
  # SPEC" ARE DIFFERENT SENTENCES. The first is about the app. The second is about us,
  # and pointing a reader at their own code for it wastes their time -- which is what
  # happened when replaying recorded query parameters turned a clean zero-404 run into
  # three of them.
  describe "a 404 that may be ours" do
    let(:not_found) { ->(_request) { { status: 404, body: "" } } }

    def detail_for(seeded)
      resolver = Loadwright::Discovery::PathParamResolver.new(config: config, seeded_ids: seeded)
      with_id = endpoint(query_params: [{ name: "warehouse_id", example: "spec-placeholder" }])

      result = runner(context: build_context(responder: not_found), resolver: resolver)
               .run(endpoints: [with_id])
      result.outcomes.first.detail
    end

    it "says the request carried an identifier we could not resolve" do
      expect(detail_for({})).to include("warehouse_id").and include("may be ours")
    end

    it "names the two ways to fix it" do
      expect(detail_for({})).to include("path_param_overrides")
    end

    # Resolved from a seeded row, so the 404 is the endpoint's own answer and saying
    # otherwise would send a reader looking at us instead of at their app.
    it "says nothing when the identifier resolved from a seeded record" do
      expect(detail_for("warehouse" => [41])).not_to include("may be ours")
    end
  end
  # THE FALLBACK THAT COULD NEVER BE REACHED. The seeded-scale axis was added so the
  # fixed/scaling classifier had something to ask on an API of single-record endpoints,
  # where there is no returned-record count to read. It never fired: the observations
  # handed to the classifier were the PAGE-SIZE cells whenever that sweep ran, and
  # those all share one seeded scale by construction. So the classifier abstained
  # while the report printed identical query counts across a hundredfold change in
  # seeded rows a few lines below it.
  describe "classifying a repeat when only the seeded scale moved" do
    it "reaches the seeded-scale axis even though the page-size sweep ran" do
      config.scale_factors = [1, 100]
      config.page_size_sweep = [5, 100]
      config.requests_per_endpoint_per_level = 2
      sql = 'SELECT "warehouses".* FROM "warehouses" WHERE "warehouses"."id" = ?'
      # A single-object response: no record count to read, which is the whole
      # premise -- and a flat query count whatever the seeded scale.
      responder = ->(_request) { { status: 200, body: JSON.generate("id" => 1) } }
      metrics = { queries: Array.new(3) { { fingerprint: sql } }, query_count: 8 }

      result = runner(context: build_context(metrics: metrics, responder: responder))
               .run(endpoints: [endpoint])
      finding = result.outcomes.first.findings.find { |f| f.kind == :n_plus_one_pattern_match }

      expect(finding.evidence[:scaling]).to eq(:fixed_by_seed_scale)
      expect(finding.suggestion).to include("pass the loaded object down")
    end
  end
  # THE SWEEP DROVE IT OUT OF RANGE. The first collection-shaped endpoint ever
  # measured answered 200 at its own default and at page size 25, and 400 at page
  # sizes 5 and 100 -- same endpoint, same resolved id, a different verdict per cell.
  # It accepts a set of page sizes and the sweep asked for values outside it.
  # Reporting that as an ordinary error status sends the reader to look at their app
  # for something the tool did.
  describe "an endpoint that rejects the page sizes the sweep chose" do
    let(:outcome) do
      config.scale_factors = [1, 100]
      config.page_size_sweep = [5, 25]
      config.requests_per_endpoint_per_level = 2
      # 400 for page size 5, 200 for everything else -- including every seed-scale
      # cell, which sends no page-size parameter at all.
      responder = lambda do |request|
        rejected = request.query[config.page_size_parameters.first].to_i == 5
        rejected ? { status: 400, body: "" } : { status: 200, body: JSON.generate([{ "id" => 1 }]) }
      end

      result = runner(context: build_context(responder: responder)).run(endpoints: [endpoint])
      result.outcomes.first
    end

    it "blames the sweep's choice of value rather than the endpoint" do
      expect(outcome.reason).to eq(:page_size_rejected)
    end

    it "names the page size it rejected and says it answered elsewhere" do
      expect(outcome.detail).to include("400 at page size 5").and include("answered successfully")
    end

    it "says what to change, and what was lost by not being able to sweep there" do
      expect(outcome.detail).to include("Set page_size_sweep").and include("N+1-behind-pagination")
    end

    # NOT loosened to healthy. Letting a partly-successful endpoint through the
    # validity gate is exactly how a 404 ended up in the healthy list; what changes
    # here is the reason and the advice, not the verdict.
    it "is still inconclusive" do
      expect(outcome).to be_inconclusive
    end

    # An endpoint failing at EVERY page size is not being driven out of range -- it is
    # failing, and the ordinary reason is the right one.
    it "does not blame the sweep when the endpoint fails everywhere" do
      config.scale_factors = [1, 100]
      config.page_size_sweep = [5, 25]
      config.requests_per_endpoint_per_level = 2
      responder = ->(_request) { { status: 400, body: "" } }

      result = runner(context: build_context(responder: responder)).run(endpoints: [endpoint])

      expect(result.outcomes.first.reason).not_to eq(:page_size_rejected)
    end
  end
end

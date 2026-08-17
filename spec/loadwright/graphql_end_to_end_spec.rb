# frozen_string_literal: true

# GRAPHQL, AGAINST A RUNNING APP.
#
# The three things that make GraphQL different from REST for this tool, each proven
# rather than described:
#
#   1. One path, one verb, N operations. Path-based discovery collapses the whole API
#      into a single row, so the operation name has to be the identity.
#   2. A failed query answers HTTP 200. Without the validity gate knowing that, a
#      total failure is reported as a fast healthy endpoint -- the exact false
#      all-clear the three-state model exists to prevent.
#   3. A GraphQL query is a READ that travels by POST. Classifying it by verb marks
#      an entire API as mutating and makes allow_mutating_requests -- a safety opt-in
#      for endpoints that WRITE -- a prerequisite for measuring reads.
RSpec.describe "GraphQL end to end", :sample_app do
  let(:stdout) { StringIO.new }

  let(:config) do
    Loadwright::Configuration.new.tap do |c|
      c.graphql_path = "/api/v1/graphql"
      c.scale_factors = [10]
      c.page_size_sweep = [5]
      c.concurrency_levels = [1]
      c.requests_per_endpoint_per_level = 4
      c.warmup_requests = 0
      c.factory_map = { "post" => { factory: :post, trait: :with_comments } }
    end
  end

  def run!(endpoints)
    reset_sample_app!
    context = Loadwright::Execution::ExecutionContext.build_in_process(config: config, app: sample_app)
    seeder = Loadwright::Seeding::FactoryBotSeeder.new(config: config, stdout: stdout)
    context.start!

    result = Loadwright::Engine::LoadRunner.new(
      config: config, context: context, seeder: seeder,
      resolver: Loadwright::Discovery::PathParamResolver.new(config: config), stdout: stdout
    ).run(endpoints: endpoints)

    context.stop!
    seeder.cleanup!
    result
  end

  def discovered = Loadwright::Discovery::GraphqlSource.new(config: config, stdout: stdout).endpoints

  describe "discovery" do
    before do
      config.graphql_operations = [
        { name: "PostsWithCommentCounts", query: "query PostsWithCommentCounts { posts { id commentCount } }" },
        { name: "AuthorCount", query: "query AuthorCount { authorCount }" }
      ]
    end

    it "gives every operation its own identity, rather than one row for the whole API" do
      expect(discovered.map(&:to_s)).to contain_exactly(
        "POST /api/v1/graphql (PostsWithCommentCounts)",
        "POST /api/v1/graphql (AuthorCount)"
      )
    end

    it "keeps them distinct through the merge, which keys on (path, verb) for REST" do
      merged = Loadwright::Discovery::Merger.new(config: config).merge(graphql: discovered)

      expect(merged.endpoints.length).to eq(2)
    end
  end

  describe "running the operations" do
    before do
      config.graphql_operations = [
        { name: "PostsWithCommentCounts", query: "query PostsWithCommentCounts { posts { id commentCount } }" }
      ]
    end

    it "measures a query without allow_mutating_requests being turned on" do
      expect(config.allow_mutating_requests).to be(false)

      result = run!(discovered)

      expect(result.cells_for("POST /api/v1/graphql (PostsWithCommentCounts)")
               .flat_map { |c| Array(c.statuses) }.uniq).to eq([200])
    end

    # The same per-record COUNT the REST fixture has, reached through a resolver.
    it "finds the resolver N+1, and suggests the fix" do
      result = run!(discovered)
      outcome = result.outcomes.find { |o| o.endpoint.graphql_operation == "PostsWithCommentCounts" }

      finding = outcome.findings.find { |f| f.kind == :n_plus_one_pattern_match }
      expect(finding).not_to be_nil
      expect(finding.suggestion).to include("counter_cache")
    end
  end

  # PAGINATION. A paginated operation returns the same page whatever the table
  # holds, so its query count is flat against seeded scale and a seeded-scale slope
  # calls it healthy. Only varying the page size moves it -- and in GraphQL the page
  # size is a variable inside the document, not a query parameter, so none of the
  # REST machinery reached it.
  describe "a paginated operation with an N+1 behind it" do
    before do
      config.page_size_sweep = [5, 10, 20]
      config.scale_factors = [25]
      config.graphql_operations = [
        { name: "PagedAuthors",
          query: "query PagedAuthors($first: Int!) { authors(first: $first) { nodes { id postCount } } }",
          variables: { "first" => 5 } }
      ]
    end

    it "recognises the page-size variable from the document" do
      expect(discovered.first.graphql_page_size_variable).to eq("first")
    end

    it "actually varies the result size, rather than measuring one page three times" do
      cells = run!(discovered).cells_for("POST /api/v1/graphql (PagedAuthors)")
                              .select { |c| c.sweep == :page_size && !c.skipped? }

      expect(cells.map(&:median_records)).to eq([5, 10, 20])
    end

    it "sees the query count rise with returned records, which seeded scale cannot" do
      cells = run!(discovered).cells_for("POST /api/v1/graphql (PagedAuthors)")
                              .select { |c| c.sweep == :page_size && !c.skipped? }

      counts = cells.map(&:median_queries)
      expect(counts).to eq(counts.sort)
      expect(counts.first).to be < counts.last
    end

    it "reports the N+1 the seeded-scale sweep alone would have missed" do
      result = run!(discovered)
      outcome = result.outcomes.find { |o| o.endpoint.graphql_operation == "PagedAuthors" }

      expect(outcome.findings.map(&:kind))
        .to include(:n_plus_one_slope).or include(:n_plus_one_pattern_match)
    end
  end

  # An operation that hardcodes its page size cannot be swept. Saying so beats
  # measuring the same page three times and reporting the flat line as healthy.
  describe "an operation that hardcodes its page size" do
    before do
      config.graphql_operations = [
        { name: "PostsWithCommentCounts", query: "query PostsWithCommentCounts { posts { id commentCount } }" }
      ]
    end

    it "is not swept, and says why" do
      result = run!(discovered)
      cells = result.cells_for("POST /api/v1/graphql (PostsWithCommentCounts)").select { |c| c.sweep == :page_size }

      expect(cells).to all(be_skipped)
      expect(result.warnings.join).to include("declares no page-size variable")
    end

    it "names the fix, so the gap is actionable" do
      expect(run!(discovered).warnings.join).to include("$first: Int!")
    end
  end

  # THE ONE THAT MATTERS MOST. HTTP 200, no data, errors present.
  describe "an operation that fails" do
    before do
      config.graphql_operations = [
        { name: "NoSuchOperation", query: "query NoSuchOperation { nope }" }
      ]
    end

    it "is not reported as a fast healthy endpoint" do
      result = run!(discovered)
      outcome = result.outcomes.find { |o| o.endpoint.graphql_operation == "NoSuchOperation" }

      expect(outcome).to be_inconclusive
      expect(outcome.reason).to eq(:graphql_errors)
    end

    it "answered 200, which is exactly why the status check alone was not enough" do
      result = run!(discovered)

      expect(result.cells_for("POST /api/v1/graphql (NoSuchOperation)")
               .flat_map { |c| Array(c.statuses) }.uniq).to eq([200])
    end

    it "quotes the GraphQL error, so the reader knows what failed" do
      result = run!(discovered)
      outcome = result.outcomes.find { |o| o.endpoint.graphql_operation == "NoSuchOperation" }

      expect(outcome.detail).to include("No operation named")
    end
  end
end

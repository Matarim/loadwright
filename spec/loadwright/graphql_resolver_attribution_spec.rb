# frozen_string_literal: true

# PER-RESOLVER ATTRIBUTION, against a real graphql-ruby schema.
#
# A GraphQL finding that names only the operation says "somewhere in this query",
# which for a query of any size is not a place to go and look. The resolver is.
#
# graphql-ruby is a DEV dependency here for one reason: this integrates with its
# tracing API, and an integration verified against a hand-rolled stand-in only
# proves the stand-in works.
RSpec.describe "GraphQL per-resolver attribution", :sample_app do
  let(:stdout) { StringIO.new }

  let(:config) do
    Loadwright::Configuration.new.tap do |c|
      c.graphql_path = "/api/v1/gql"
      c.scale_factors = [12]
      c.page_size_sweep = [3, 6, 12]
      c.concurrency_levels = [1]
      c.requests_per_endpoint_per_level = 3
      c.warmup_requests = 0
      c.factory_map = { "post" => { factory: :post, trait: :with_comments } }
    end
  end

  def run!
    reset_sample_app!
    context = Loadwright::Execution::ExecutionContext.build_in_process(config: config, app: sample_app)
    seeder = Loadwright::Seeding::FactoryBotSeeder.new(config: config, stdout: stdout)
    context.start!

    endpoints = Loadwright::Discovery::GraphqlSource.new(config: config, stdout: stdout).endpoints
    result = Loadwright::Engine::LoadRunner.new(
      config: config, context: context, seeder: seeder,
      resolver: Loadwright::Discovery::PathParamResolver.new(config: config), stdout: stdout
    ).run(endpoints: endpoints)

    context.stop!
    seeder.cleanup!
    result
  end

  def finding_for(result, operation)
    result.outcomes
          .find { |o| o.endpoint.graphql_operation == operation }
          .findings.find { |f| f.kind == :n_plus_one_pattern_match }
  end

  describe "two operations whose N+1s live in different resolvers" do
    before do
      config.graphql_operations = [
        { name: "PagedAuthors",
          query: "query PagedAuthors($first: Int!) { authors(first: $first) { id postCount } }",
          variables: { "first" => 3 } },
        { name: "PagedPosts",
          query: "query PagedPosts($first: Int!) { posts(first: $first) { id commentCount } }",
          variables: { "first" => 3 } }
      ]
    end

    it "names the resolver that issued the repeated query, not just the operation" do
      result = run!

      expect(finding_for(result, "PagedAuthors").evidence[:resolver]).to eq("Author.postCount")
    end

    # The control: a second operation whose N+1 is in a DIFFERENT resolver. Without
    # it, attribution could be returning one constant and still pass above.
    it "tells two resolvers apart" do
      result = run!

      expect(finding_for(result, "PagedPosts").evidence[:resolver]).to eq("Post.commentCount")
    end

    it "puts the resolver in the sentence a reader actually sees" do
      expect(finding_for(run!, "PagedAuthors").detail).to include("resolved by Author.postCount")
    end
  end

  # Attribution must not come at the cost of the signal it annotates.
  describe "the findings themselves" do
    before do
      config.graphql_operations = [
        { name: "PagedAuthors",
          query: "query PagedAuthors($first: Int!) { authors(first: $first) { id postCount } }",
          variables: { "first" => 3 } }
      ]
    end

    it "still sweeps the page size and sees the slope" do
      result = run!
      cells = result.cells_for("POST /api/v1/gql (PagedAuthors)").select { |c| c.sweep == :page_size && !c.skipped? }

      expect(cells.map(&:median_records)).to eq([3, 6, 12])
      expect(cells.map(&:median_queries)).to eq(cells.map(&:median_queries).sort)
    end

    it "still suggests the fix" do
      expect(finding_for(run!, "PagedAuthors").suggestion).to include("counter_cache")
    end
  end

  # The tracer is a no-op outside a run, so a host app can leave it installed.
  it "attributes nothing when no run is in progress" do
    reset_sample_app!
    FactoryBot.create(:post)
    Loadwright::Instrumentation::CurrentField.clear!

    SampleGraphql::Schema.execute("query { authors(first: 1) { id postCount } }")

    expect(Loadwright::Instrumentation::CurrentField.path).to be_nil
  end
end

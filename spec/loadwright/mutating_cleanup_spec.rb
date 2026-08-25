# frozen_string_literal: true

# A REAL MUTATING RUN, against a real database, proving it leaves nothing behind.
#
# This is the gap that kept allow_mutating_requests off in practice. Cleanup tracked
# what the FACTORIES wrote and nothing else, so a run against a POST endpoint left one
# row per request in the developer's database -- from a tool whose headline promise is
# that it does not litter. The same was true of a GET that writes an audit row or
# touches a last_seen_at, which plenty of apps do.
#
# It has to be an end-to-end run rather than a unit test of the seeder: the whole
# mechanism is that the runner reads INSERT table names off the query fingerprints it
# is already collecting, and hands them to the seeder. Stubbing either half would test
# the wiring against itself.
RSpec.describe "cleanup after a mutating run", :sample_app do
  let(:stdout) { StringIO.new }

  let(:config) do
    Loadwright::Configuration.new.tap do |c|
      c.scale_factors = [5]
      c.page_size_sweep = [5]
      c.concurrency_levels = [1]
      c.requests_per_endpoint_per_level = 6
      c.warmup_requests = 0
      c.allow_mutating_requests = true
      c.factory_map = { "post" => { factory: :post, trait: :with_comments } }
    end
  end

  def create_endpoint
    Loadwright::Discovery::Endpoint.new(
      path: "/api/v1/posts", verb: :post, source: :openapi,
      request_body: { "title" => "load", "body" => "test" }
    )
  end

  # Resets first, so a caller that wants a pre-existing row can create one after.
  before { reset_sample_app! }

  # Returns [rows_during_run, seeder]
  def run_against_create!
    context = Loadwright::Execution::ExecutionContext.build_in_process(config: config, app: sample_app)
    seeder = Loadwright::Seeding::FactoryBotSeeder.new(config: config, stdout: stdout)
    context.start!

    Loadwright::Engine::LoadRunner.new(
      config: config, context: context, seeder: seeder,
      resolver: Loadwright::Discovery::PathParamResolver.new(config: config), stdout: stdout
    ).run(endpoints: [create_endpoint])

    during = Post.count
    context.stop!
    [during, seeder]
  end

  it "actually issues the POSTs, or the rest of this proves nothing" do
    during, seeder = run_against_create!
    seeder.cleanup!

    # 5 seeded + one per request. The exact count matters less than "more than seeded".
    expect(during).to be > 5
  end

  it "deletes the rows the app created answering them" do
    _during, seeder = run_against_create!

    seeder.cleanup!

    expect(Post.count).to eq(0)
  end

  # The mechanism, asserted directly: the table was learned from the INSERT
  # fingerprints the runner already collects, not from anything the seeder wrote.
  it "learns which table the requests wrote to from the queries they issued" do
    _during, seeder = run_against_create!

    expect(seeder.request_written_tables).to include("posts")
    expect(seeder.to_h[:tables_written_by_requests]).to include("posts")
  end

  it "still leaves rows that existed before the run completely alone" do
    survivor = FactoryBot.create(:post, title: "I was here first")

    _during, seeder = run_against_create!
    seeder.cleanup!

    expect(Post.pluck(:id)).to eq([survivor.id])
  end
end

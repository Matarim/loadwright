# frozen_string_literal: true

# AN API THAT ROUTES ON A PUBLIC IDENTIFIER, not on the primary key.
#
# Guids, slugs and uuids are the default for any API that declines to leak sequential
# ids -- `to_param` and `friendly_id` exist for exactly this. Substituting the primary
# key into such a path 404s every request, and the endpoint is then reported as broken
# when the tool simply asked for the wrong thing.
#
# `authors/by-slug/{slug}` is the fixture's version of that shape: a real column, a
# real lookup, a real 404 when it is wrong.
RSpec.describe "an endpoint keyed on a public identifier", :sample_app do
  let(:stdout) { StringIO.new }

  let(:config) do
    Loadwright::Configuration.new.tap do |c|
      c.scale_factors = [3]
      c.page_size_sweep = [3]
      c.concurrency_levels = [1]
      c.requests_per_endpoint_per_level = 2
      c.warmup_requests = 0
    end
  end

  let(:endpoint) do
    Loadwright::Discovery::Endpoint.new(
      path: "/api/v1/authors/by-slug/{author_slug}", verb: :get, source: :openapi,
      recorded_path_values: { author_slug: %w[does-not-exist] }
    )
  end

  def run!
    reset_sample_app!
    context = Loadwright::Execution::ExecutionContext.build_in_process(config: config, app: sample_app)
    seeder = Loadwright::Seeding::FactoryBotSeeder.new(config: config, stdout: stdout)
    context.start!
    result = Loadwright::Engine::LoadRunner.new(
      config: config, context: context, seeder: seeder,
      resolver: Loadwright::Discovery::PathParamResolver.new(config: config), stdout: stdout
    ).run(endpoints: [endpoint])
    context.stop!
    seeder.cleanup!
    result
  end

  def statuses(result) = result.cells_for("GET /api/v1/authors/by-slug/{author_slug}").flat_map { |c| Array(c.statuses) }.uniq

  # The failure this fixes: the primary key goes into a path that wants a slug.
  it "404s when the primary key is substituted into a slug route" do
    config.factory_map = { "author" => { factory: :author } }

    expect(statuses(run!)).to eq([404])
  end

  # factory_map names the column the API actually routes on. This is where the
  # knowledge belongs -- the user already had to say which factory builds the record.
  it "succeeds when factory_map names the identifier the API uses" do
    config.factory_map = { "author" => { factory: :author, param: :slug } }

    expect(statuses(run!)).to eq([200])
  end

  # AN EXPLICIT OVERRIDE WINS, even over a seeded value. It used to sit third, behind
  # two inferences, so on exactly the APIs it exists for it was never consulted.
  it "prefers an explicit override over a seeded primary key" do
    config.factory_map = { "author" => { factory: :author } }
    config.path_param_overrides = {
      "/api/v1/authors/by-slug/{author_slug}" => { author_slug: -> { Author.order(:id).first&.slug } }
    }

    expect(statuses(run!)).to eq([200])
  end

  # Cleanup is bounded by PRIMARY KEY and must stay that way, whatever the API routes
  # on. Naming another column must not widen what cleanup can reach.
  it "still cleans up by primary key when the param is a slug" do
    config.factory_map = { "author" => { factory: :author, param: :slug } }
    # Created inside the run, via the seeder's own cleanup boundary: `run!` resets the
    # fixture first, so anything made before it would be wiped by the setup rather
    # than by cleanup, and the example would pass for the wrong reason.
    reset_sample_app!
    survivor = FactoryBot.create(:author)
    allow(self).to receive(:reset_sample_app!)

    run!

    expect(Author.pluck(:id)).to eq([survivor.id])
  end
end

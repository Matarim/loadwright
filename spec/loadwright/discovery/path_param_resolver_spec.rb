# frozen_string_literal: true

RSpec.describe Loadwright::Discovery::PathParamResolver do
  let(:config) { Loadwright::Configuration.new }

  def endpoint(path:, verb: :get, source: :openapi, **rest)
    Loadwright::Discovery::Endpoint.new(path: path, verb: verb, source: source, **rest)
  end

  def resolver(seeded: {})
    described_class.new(config: config, seeded_ids: seeded)
  end

  describe "an endpoint with no path params" do
    it "resolves to itself without consulting anything" do
      resolution = resolver.resolve(endpoint(path: "/api/v1/posts"))

      expect(resolution.path).to eq("/api/v1/posts")
      expect(resolution.values).to be_empty
    end
  end

  describe "resolution order" do
    let(:target) do
      endpoint(
        path: "/api/v1/posts/{id}/comments",
        recorded_path_values: { id: %w[recorded-1] },
        query_params: [{ name: "id", example: "openapi-example" }]
      )
    end

    # 1. AN EXPLICIT OVERRIDE WINS. The user has stated a fact the tool inferred
    #    wrongly, and it is opt-in and empty by default, so nothing is lost by
    #    trusting it. It used to sit THIRD -- behind seeded and recorded ids -- which
    #    meant it was never consulted on the exact APIs it exists for: one routing on
    #    a public guid or slug got a primary key substituted, 404'd every request, and
    #    the documented fix ("add path_param_overrides") could not take effect.
    it "prefers an explicit override over everything else" do
      config.path_param_overrides = { "/api/v1/posts/{id}/comments" => { id: "override" } }

      resolution = resolver(seeded: { "post" => [4271] }).resolve(target)

      expect(resolution.path).to eq("/api/v1/posts/override/comments")
      expect(resolution.sources[:id]).to eq(:override)
    end

    # 2. A seeded record's identifier -- the only source guaranteed to exist in the
    #    database right now.
    it "falls back to a seeded id when there is no override" do
      resolution = resolver(seeded: { "post" => [4271] }).resolve(target)

      expect(resolution.path).to eq("/api/v1/posts/4271/comments")
      expect(resolution.sources[:id]).to eq(:seeded)
    end

    # 3. An id a spec demonstrably used successfully.
    it "falls back to a recorded id" do
      resolution = resolver.resolve(target)

      expect(resolution.path).to eq("/api/v1/posts/recorded-1/comments")
      expect(resolution.sources[:id]).to eq(:recorded)
    end

    # 3. An explicit override — the escape hatch for slugs, UUIDs and composite
    #    keys nothing can infer.
    it "falls back to a configured override" do
      config.path_param_overrides = { "/api/v1/posts/{id}/comments" => { id: "override" } }
      bare = endpoint(path: "/api/v1/posts/{id}/comments")

      expect(resolver.resolve(bare).sources[:id]).to eq(:override)
    end

    it "calls a callable override, so a slug can be looked up at run time" do
      config.path_param_overrides = { "/api/v1/posts/{slug}" => { slug: -> { "hello-world" } } }

      expect(resolver.resolve(endpoint(path: "/api/v1/posts/{slug}")).path).to eq("/api/v1/posts/hello-world")
    end

    it "treats a raising override as unresolved rather than taking the run down" do
      config.path_param_overrides = { "/api/v1/posts/{slug}" => { slug: -> { raise "no such record" } } }

      expect(resolver.resolve(endpoint(path: "/api/v1/posts/{slug}")))
        .to be_a(described_class::Unresolved)
    end

    # 4. The OpenAPI example, last, because it is least likely to correspond to
    #    real data.
    it "uses the OpenAPI example last" do
      only_example = endpoint(path: "/api/v1/posts/{id}/comments",
                              query_params: [{ name: "id", example: "openapi-example" }])

      expect(resolver.resolve(only_example).sources[:id]).to eq(:example)
    end
  end

  describe "resolving the resource a param belongs to" do
    it "uses the segment preceding {id}" do
      resolution = resolver(seeded: { "post" => [7] }).resolve(endpoint(path: "/api/v1/posts/{id}"))

      expect(resolution.path).to eq("/api/v1/posts/7")
    end

    it "uses the prefix of {post_id} directly" do
      resolution = resolver(seeded: { "post" => [7] }).resolve(endpoint(path: "/api/v1/posts/{post_id}/comments"))

      expect(resolution.path).to eq("/api/v1/posts/7/comments")
    end

    it "resolves several params in one path" do
      resolution = resolver(seeded: { "post" => [7], "comment" => [99] })
                   .resolve(endpoint(path: "/api/v1/posts/{post_id}/comments/{id}"))

      expect(resolution.path).to eq("/api/v1/posts/7/comments/99")
    end

    {
      "categories" => "category",
      "posts" => "post",
      "addresses" => "address",
      "boxes" => "box"
    }.each do |plural, singular|
      it "singularises #{plural} to #{singular}" do
        resolution = resolver(seeded: { singular => [1] }).resolve(endpoint(path: "/api/v1/#{plural}/{id}"))

        expect(resolution.path).to eq("/api/v1/#{plural}/1")
      end
    end

    it "accepts symbol keys from the seeder too" do
      resolution = resolver(seeded: { post: [7] }).resolve(endpoint(path: "/api/v1/posts/{id}"))

      expect(resolution.path).to eq("/api/v1/posts/7")
    end
  end

  describe "rotation" do
    # A single hot row produces unrealistic cache behaviour and can create row-lock
    # contention that does not reflect real traffic.
    it "rotates through seeded ids across requests rather than hammering one row" do
      subject = resolver(seeded: { "post" => [1, 2, 3] })
      target = endpoint(path: "/api/v1/posts/{id}")

      paths = (0..5).map { |index| subject.resolve(target, index: index).path }

      expect(paths).to eq(%w[
        /api/v1/posts/1 /api/v1/posts/2 /api/v1/posts/3
        /api/v1/posts/1 /api/v1/posts/2 /api/v1/posts/3
      ])
    end

    it "rotates recorded ids too" do
      subject = resolver
      target = endpoint(path: "/api/v1/posts/{id}", recorded_path_values: { id: %w[42 43] })

      expect((0..2).map { |i| subject.resolve(target, index: i).values[:id] }).to eq(%w[42 43 42])
    end
  end

  # A LITERAL `{` MUST NEVER LEAVE THE BUILDING. `path_params` was taken verbatim
  # from a recording's `path_values` keys, so an empty hash meant "this endpoint has
  # no parameters" -- even though its template plainly contains one. Resolution
  # early-returned, and the raw template went out as a URL:
  #
  #   URI::InvalidURIError: bad URI ... /api/v1/posts/{id}/comments
  #
  # 25 times a cell, tripping the breaker at 100%. The unresolved BRANCH is handled
  # well; this simply never reached it.
  describe "a template whose parameters were not declared" do
    it "still treats the template's parameters as parameters" do
      target = endpoint(path: "/api/v1/posts/{id}/comments", path_params: [])

      expect(target.path_params).to eq([:id])
    end

    it "reports it unresolved rather than requesting the raw template" do
      target = endpoint(path: "/api/v1/posts/{id}/comments", path_params: [])

      result = resolver.resolve(target)

      expect(result).to be_a(described_class::Unresolved)
    end

    # Belt and braces at the choke point: whatever a source returns, a path that still
    # carries a placeholder is unresolved, not a request.
    it "refuses a substitution that leaves a placeholder behind" do
      target = endpoint(path: "/api/v1/posts/{id}/comments/{comment_id}",
                        recorded_path_values: { id: %w[7] })

      result = resolver.resolve(target)

      expect(result).to be_a(described_class::Unresolved)
    end
  end

  describe "when nothing resolves" do
    # Sending a placeholder id and then reporting the resulting 404 as a
    # performance result is the specific failure this class exists to prevent.
    it "returns Unresolved naming the specific param, not a placeholder path" do
      result = resolver.resolve(endpoint(path: "/api/v1/posts/{slug}/revisions/{revision_id}"))

      expect(result).to be_a(described_class::Unresolved)
      expect(result.params).to eq(%i[slug revision_id])
      expect(result.detail).to eq("could not resolve {slug}, {revision_id}")
    end

    it "reports only the params that failed, when some resolved" do
      result = resolver(seeded: { "post" => [1] })
               .resolve(endpoint(path: "/api/v1/posts/{post_id}/attachments/{token}"))

      expect(result.params).to eq([:token])
    end
  end

  describe "#seeded_ids=" do
    it "picks up ids the seeder created after the resolver was built" do
      subject = resolver
      target = endpoint(path: "/api/v1/posts/{id}")
      expect(subject.resolve(target)).to be_a(described_class::Unresolved)

      subject.seeded_ids = { "post" => [11] }

      expect(subject.resolve(target).path).to eq("/api/v1/posts/11")
    end
  end

  # A LOOKUP MISS LOOKS EXACTLY LIKE HAVING NO factory_map ENTRY.
  #
  # The key is matched against a name derived from the PATH PARAMETER, not from the
  # factory -- `{caller_number}` looks under "caller" -- so a key named after the
  # factory silently misses and resolution falls through to the recorded literal. One
  # integration configured `value:` correctly, watched 100 rows seed, saw no warning,
  # and had the recorded literal sent anyway; establishing why cost a probe and a
  # cross-round diff.
  describe "a seeded resource no endpoint asked for" do
    let(:endpoint) do
      Loadwright::Discovery::Endpoint.new(path: "/api/v1/widgets/{widget_number}", verb: :get,
                                          source: :route)
    end

    it "names what was seeded and what endpoints actually looked for" do
      resolver = described_class.new(config: config, seeded_ids: { "account" => %w[a1 a2] })
      resolver.resolve(endpoint)

      warning = resolver.unconsumed_warning
      expect(warning).to include('"account"')
      expect(warning).to include('"widget"')
      expect(warning).to include("PATH PARAMETER")
    end

    it "says nothing when the seeded resource was used" do
      resolver = described_class.new(config: config, seeded_ids: { "widget" => %w[w1] })
      resolver.resolve(endpoint)

      expect(resolver.unconsumed_warning).to be_nil
    end

    # Nothing resolved at all is a different problem with its own reporting, and a
    # warning about key names would be noise on top of it.
    it "says nothing when no endpoint resolved a path parameter at all" do
      resolver = described_class.new(config: config, seeded_ids: { "account" => %w[a1] })

      expect(resolver.unconsumed_warning).to be_nil
    end

    it "reports which source won, so a seeded value losing is visible" do
      resolver = described_class.new(config: config, seeded_ids: { "widget" => %w[w1] })

      expect(resolver.resolve(endpoint).sources).to eq(widget_number: :seeded)
    end
  end

  # ONE RESOURCE, TWO IDENTIFIER COLUMNS, CHOSEN BY PARAMETER NAME. A record addressed by
  # a GUID on one mount and a number on another cannot be expressed by one value per
  # resource -- and `{resource_id}` and `resource_number` both derive to "resource", so
  # setting it for one mount breaks the other.
  describe "a resource addressed differently per parameter" do
    let(:endpoint) do
      Loadwright::Discovery::Endpoint.new(path: "/api/v1/resources/{resource_id}", verb: :get,
                                          source: :route)
    end

    let(:seeded) do
      { "resource" => %w[fallback-1 fallback-2],
        "resource_id" => %w[guid-1 guid-2],
        "resource_number" => %w[num-1 num-2] }
    end

    it "prefers the parameter-keyed value for a path segment" do
      resolver = described_class.new(config: config, seeded_ids: seeded)

      expect(resolver.resolve(endpoint).path).to eq("/api/v1/resources/guid-1")
    end

    it "prefers the parameter-keyed value for a query parameter" do
      resolver = described_class.new(config: config, seeded_ids: seeded)

      expect(resolver.resolve_query_param("resource_number")).to eq("num-1")
    end

    # CORRELATION. Both lists come from the same records in the same order and rotate on
    # a shared index, so one request's GUID and number are the same row. Selecting them
    # independently produces two valid values from two different graphs -- still a 404,
    # and it looks like the application's fault.
    it "keeps the two in step, so one request gets one row" do
      resolver = described_class.new(config: config, seeded_ids: seeded)

      expect(resolver.resolve(endpoint, index: 1).path).to eq("/api/v1/resources/guid-2")
      expect(resolver.resolve_query_param("resource_number", index: 1)).to eq("num-2")
    end

    it "falls through to the resource's shared value for a parameter with no entry" do
      resolver = described_class.new(config: config, seeded_ids: { "resource" => %w[shared-1] })

      expect(resolver.resolve(endpoint).path).to eq("/api/v1/resources/shared-1")
    end
  end

  # THE REPORT ADVISED A SETTING THIS RESOLVER NEVER READ, so the prescribed fix could
  # not affect the request -- the same failure as a documented remedy sitting behind a
  # code path that cannot reach it.
  describe "an override for an identifier-shaped query parameter" do
    it "is consulted, and beats a seeded value" do
      config.path_param_overrides = { "widget_number" => "override-me" }
      resolver = described_class.new(config: config, seeded_ids: { "widget" => %w[seeded] })

      expect(resolver.resolve_query_param("widget_number")).to eq("override-me")
    end

    it "rotates a list of override values" do
      config.path_param_overrides = { "widget_number" => %w[a b] }
      resolver = described_class.new(config: config, seeded_ids: {})

      expect(resolver.resolve_query_param("widget_number", index: 1)).to eq("b")
    end

    it "leaves an ordinary filter parameter alone" do
      config.path_param_overrides = { "widget_number" => "x" }
      resolver = described_class.new(config: config, seeded_ids: {})

      expect(resolver.resolve_query_param("view")).to be_nil
    end
  end
end

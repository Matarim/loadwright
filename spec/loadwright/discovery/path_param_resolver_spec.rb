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

    # 1. A seeded record's real id. The primary path, and the only source
    #    guaranteed to exist in the database right now.
    it "prefers a seeded id over everything else" do
      config.path_param_overrides = { "/api/v1/posts/{id}/comments" => { id: "override" } }

      resolution = resolver(seeded: { "post" => [4271] }).resolve(target)

      expect(resolution.path).to eq("/api/v1/posts/4271/comments")
      expect(resolution.sources[:id]).to eq(:seeded)
    end

    # 2. An id a spec demonstrably used successfully.
    it "falls back to a recorded id" do
      config.path_param_overrides = { "/api/v1/posts/{id}/comments" => { id: "override" } }

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
end

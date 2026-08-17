# frozen_string_literal: true

RSpec.describe Loadwright::Discovery::RouteSource do
  let(:config) { Loadwright::Configuration.new }
  let(:routes) { blog_route_set }

  subject(:source) { described_class.new(config: config, routes: routes) }

  describe "#endpoints" do
    it "produces endpoints in the OpenAPI template form, so they merge" do
      expect(source.endpoints.map(&:to_s)).to include(
        "GET /api/v1/posts",
        "GET /api/v1/posts/{id}",
        "GET /api/v1/posts/{post_id}/comments",
        "GET /api/v1/authors/{slug}"
      )
    end

    it "strips the (.:format) suffix rather than inventing a {format} param" do
      show = source.endpoints.find { |e| e.key == ["/api/v1/posts/{id}", :get] }

      expect(show.path_params).to eq([:id])
      expect(show.path).not_to include("format")
    end

    it "separates verbs on the same path" do
      posts = source.endpoints.select { |e| e.path == "/api/v1/posts" }.map(&:verb)

      expect(posts).to contain_exactly(:get, :post)
    end

    it "records the controller and action, which is all a route knows" do
      expect(source.endpoints.find { |e| e.key == ["/api/v1/posts", :get] }.description)
        .to eq("api/v1/posts#index")
    end

    it "marks every endpoint as route-sourced" do
      expect(source.endpoints.map(&:sources).uniq).to eq([[:route]])
    end

    # Exercising these measures Rails, not the app under test.
    it "excludes Rails' own internal routes" do
      expect(source.endpoints.map(&:path)).not_to include(a_string_matching(%r{^/rails/}))
    end

    # This is gap-filling only. A route knows a path and a verb; nothing about a
    # valid body. A mutating route-sourced endpoint has no example, and
    # discovery-and-load-engine.md says report that rather than guess.
    it "has no example for a mutating endpoint, so the merger can skip and name it" do
      create = source.endpoints.find { |e| e.key == ["/api/v1/posts", :post] }

      expect(create).not_to be_example_available
    end

    it "does not duplicate a path/verb pair" do
      keys = source.endpoints.map(&:key)

      expect(keys.length).to eq(keys.uniq.length)
    end
  end

  describe "route_discovery = false" do
    it "produces nothing at all" do
      config.route_discovery = false

      expect(source.endpoints).to be_empty
    end
  end

  describe "with no route set available" do
    # hide_const rather than relying on Rails being absent: examples/sample_app boots
    # a real Rails application, so whether Rails.application.routes exists here
    # depends on spec ORDER.
    it "reports itself unavailable rather than raising" do
      hide_const("Rails")
      subject = described_class.new(config: config, routes: nil)

      expect(subject).not_to be_available
      expect(subject.endpoints).to eq([])
    end
  end
end

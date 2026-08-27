# frozen_string_literal: true

# A LEADING `//` IS A PROTOCOL-RELATIVE URL. Rack parses one as such, so the first
# segment is read as the authority and silently disappears -- the router is then asked
# about a path missing its first segment, answers nil, and the recording is dropped.
#
# Every one of twenty-two recordings lost in one real run had this shape, all from a
# single mounted Rack app whose mount point and sub-path each contributed a slash. The
# router recognised both forms when asked directly; the loss was entirely inside
# request construction.
RSpec.describe Loadwright::Discovery::RouteRecognizer do
  describe ".normalize_slashes" do
    it "collapses a doubled leading slash, which Rack would read as an authority" do
      expect(described_class.normalize_slashes("//api/v1/widgets/7")).to eq("/api/v1/widgets/7")
    end

    it "collapses an interior run, which a mount point and a sub-path produce together" do
      expect(described_class.normalize_slashes("/internal//widgets/7")).to eq("/internal/widgets/7")
    end

    it "leaves an ordinary path alone" do
      expect(described_class.normalize_slashes("/api/v1/widgets/7")).to eq("/api/v1/widgets/7")
    end

    it "keeps the query string" do
      expect(described_class.normalize_slashes("//api/v1/widgets?view=full")).to eq("/api/v1/widgets?view=full")
    end
  end

  # The bug reproduced against Rack itself, so this file states the premise rather
  # than assuming it: if Rack ever stops parsing `//` as protocol-relative, the
  # normalisation becomes unnecessary rather than wrong, and this example says so.
  describe "the Rack behaviour this exists to work around" do
    it "drops the first segment of a doubled-slash path" do
      require "rack/mock_request"

      expect(Rack::MockRequest.env_for("//api/v1/widgets/7")["PATH_INFO"]).to eq("/v1/widgets/7")
      expect(Rack::MockRequest.env_for("/api/v1/widgets/7")["PATH_INFO"]).to eq("/api/v1/widgets/7")
    end
  end

  describe "#recognize" do
    # PLAIN doubles, not verifying ones. The collaborators here are Journey internals
    # -- Route, Path::Pattern -- and pinning a spec to their surface would couple this
    # file to private Rails API for no gain, which is the hazard M0 decision 13 already
    # names about the OpenAPI parser. What matters is the path the router is ASKED
    # about, and that is ours.
    let(:seen_paths) { [] }

    let(:router) do
      route = double("route", path: double("path", spec: double("pattern", to_s: "/api/v1/widgets/:id(.:format)")))
      recorded = seen_paths
      router = Object.new
      router.define_singleton_method(:recognize) do |request, &block|
        recorded << request.path_info
        block.call(route, { controller: "widgets", action: "show", id: "7" })
      end
      router
    end

    subject(:recognizer) { described_class.new(routes: double("routes", router: router)) }

    it "asks the router about the whole path, not one missing its first segment" do
      recognizer.recognize(:get, "//api/v1/widgets/7")

      expect(seen_paths).to eq(["/api/v1/widgets/7"])
    end

    it "recognises the doubled form exactly as it recognises the single one" do
      doubled = recognizer.recognize(:get, "//api/v1/widgets/7")
      single = recognizer.recognize(:get, "/api/v1/widgets/7")

      expect(doubled&.template).to eq(single&.template)
      expect(doubled&.template).to eq("/api/v1/widgets/{id}")
    end
  end
end

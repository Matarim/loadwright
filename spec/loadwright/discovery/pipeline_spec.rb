# frozen_string_literal: true

require "tmpdir"

RSpec.describe Loadwright::Discovery::Pipeline do
  let(:config) { Loadwright::Configuration.new }
  let(:stdout) { StringIO.new }

  subject(:pipeline) { described_class.new(config: config, stdout: stdout) }

  # AN EMPTY DIRECTORY, STATED RATHER THAN ASSUMED. `report_output_dir` has a LAZY
  # DEFAULT derived from `rails_root`, so where the integration-spec recording is
  # looked for depends on whether a :sample_app example has already booted Rails into
  # this process -- and if one has, the path resolves into the fixture's own tree,
  # where a real recording may well be sitting.
  #
  # This is not hypothetical: the "tells the user how to produce a recording"
  # example below passed on its own and failed in the full suite, because a manual
  # CLI run had left a recorded-requests.json exactly where the lazy default pointed.
  around do |example|
    Dir.mktmpdir("pipeline-") do |dir|
      config.report_output_dir = dir
      example.run
    end
  end

  def endpoint(path, verb: :get, source: :route)
    Loadwright::Discovery::Endpoint.new(path: path, verb: verb, source: source)
  end

  # Sources are stubbed rather than driven: what this class is responsible for is the
  # ORDER and the WARNINGS, not the parsing, which each source specs for itself.
  def stub_sources(openapi: [], recorded: [], routes: [])
    allow_any_instance_of(Loadwright::Discovery::OpenapiSource).to receive(:endpoints).and_return(openapi)
    allow_any_instance_of(Loadwright::Discovery::OpenapiSource).to receive(:warnings).and_return([])
    allow_any_instance_of(Loadwright::Discovery::RouteSource).to receive(:endpoints).and_return(routes)
    allow_any_instance_of(Loadwright::Discovery::IntegrationSpecSource)
      .to receive(:endpoints).and_return(recorded)
    allow_any_instance_of(Loadwright::Discovery::IntegrationSpecSource).to receive(:warnings).and_return([])
  end

  describe "warnings about sources that found nothing" do
    # THE NOISE PROBLEM. Both path settings have LAZY DEFAULTS pointing at
    # conventional locations (swagger/v1/swagger.yaml, spec/requests). Warning
    # whenever the value is non-empty meant every app without a swagger directory got
    # two warnings about sources it had never asked for -- on every run. A warning
    # channel that cries wolf on a default configuration stops being read, which
    # costs the warnings that matter.
    it "stays quiet about an OpenAPI document the user never asked for" do
      stub_sources(routes: [endpoint("/a")])

      expect(pipeline.discover.warnings.join).not_to include("openapi_spec_paths")
    end

    it "warns when the user pointed openapi_spec_paths somewhere and nothing came back" do
      config.openapi_spec_paths = ["docs/openapi.yaml"]
      stub_sources(routes: [endpoint("/a")])

      expect(pipeline.discover.warnings.join).to include("docs/openapi.yaml")
    end

    it "stays quiet about a missing recording the user never asked for" do
      stub_sources(routes: [endpoint("/a")])

      expect(pipeline.discover.warnings.join).not_to include("loadwright record")
    end

    # Naming the command is the point: "no recording exists" without it leaves the
    # user knowing something is missing and not how to produce it.
    it "tells the user how to produce a recording they configured but never made" do
      config.integration_spec_paths = ["spec/requests"]
      stub_sources(routes: [endpoint("/a")])

      expect(pipeline.discover.warnings.join).to include("loadwright record --specs spec/requests")
    end
  end

  describe "--only" do
    it "narrows the endpoint list" do
      stub_sources(routes: [endpoint("/api/posts"), endpoint("/api/authors")])

      expect(pipeline.discover(only: "posts").endpoints.map(&:path)).to eq(["/api/posts"])
    end

    # Otherwise `--only posts` produces a report whose "not tested" section lists
    # every author endpoint, which reads as a coverage failure rather than as the
    # filter the user asked for.
    it "narrows the skipped list too, so the report is about what was asked for" do
      config.allow_mutating_requests = false
      stub_sources(routes: [endpoint("/api/posts", verb: :post), endpoint("/api/authors", verb: :post)])

      result = pipeline.discover(only: "posts")

      expect(result.skipped.map { |o| o.endpoint.path }).to eq(["/api/posts"])
    end

    # Silence here would look exactly like "your API has no endpoints", which sends
    # the user to look at discovery instead of at their own typo.
    it "says so when the filter matched nothing" do
      stub_sources(routes: [endpoint("/api/posts")])

      result = pipeline.discover(only: "widgets")

      expect(result.endpoints).to be_empty
      expect(result.warnings.join).to include("matched none of the 1 discovered endpoint")
    end
  end

  # Route introspection reaches into the host's router, which can raise for reasons
  # that have nothing to do with the run. Losing the gap-filling source is
  # survivable; losing the run because of it is not.
  it "survives a route source that raises, and says it did" do
    # Set explicitly: outside a Rails app the lazy default for this key resolves to
    # nothing, so the OpenAPI source would short-circuit before reaching the stub.
    config.openapi_spec_paths = ["docs/openapi.yaml"]
    stub_sources(openapi: [endpoint("/a", source: :openapi)])
    allow_any_instance_of(Loadwright::Discovery::RouteSource)
      .to receive(:endpoints).and_raise(NoMethodError, "undefined method 'routes'")

    result = pipeline.discover

    expect(result.endpoints.map(&:path)).to eq(["/a"])
    expect(result.warnings.join).to include("route discovery failed")
  end

  it "reports what each source contributed" do
    config.openapi_spec_paths = ["docs/openapi.yaml"]
    stub_sources(openapi: [endpoint("/a", source: :openapi)], routes: [endpoint("/b")])

    expect(pipeline.discover.by_source).to include(openapi: 1, route: 1)
  end
end

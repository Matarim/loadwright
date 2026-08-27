# frozen_string_literal: true

require "action_dispatch/testing/integration"
require "tmpdir"

# Exercises the recorder through a REAL ActionDispatch::Integration::Session
# against a REAL route set, because both halves of what it does are integration
# concerns: hooking #process without changing behaviour, and agreeing with the
# router about which template matched.
RSpec.describe Loadwright::Discovery::IntegrationSpecSource do
  let(:config) { Loadwright::Configuration.new }
  let(:routes) { blog_route_set }
  let(:recognizer) { Loadwright::Discovery::RouteRecognizer.new(routes: routes) }

  subject(:source) do
    described_class.new(config: config, recognizer: recognizer, stdout: StringIO.new)
  end

  # A Rack app that answers anything. What the app returns is irrelevant here; what
  # matters is what the recorder captured about the request.
  let(:app) do
    lambda do |env|
      [200, { "content-type" => "application/json" }, [JSON.generate("path" => env["PATH_INFO"])]]
    end
  end

  def session = ActionDispatch::Integration::Session.new(app)

  around do |example|
    Dir.mktmpdir("loadwright-recording") do |dir|
      @output = File.join(dir, "recorded-requests.json")
      example.run
    end
  end

  after { source.uninstall! }

  def record(&block)
    source.record!(output_path: @output) { block.call }
    JSON.parse(File.read(@output))
  end

  describe "recording rather than parsing" do
    # SKILL.md's pitfall list is explicit: a static parser looking for `get "/foo"`
    # in arbitrary RSpec files is coupled to how each team writes specs, and it
    # fails by silently under-discovering. This class must not contain an AST
    # walker.
    it "hooks the one funnel every verb goes through" do
      source.install!

      expect(ActionDispatch::Integration::Session.ancestors).to include(described_class::Recorder)
    end

    it "reads no spec files at all" do
      expect(File.read(File.join(SpecPaths::LIB, "discovery", "integration_spec_source.rb")))
        .not_to match(/Ripper|RubyVM::AbstractSyntaxTree|Prism|parse_file/)
    end

    it "does not change what the request returns" do
      source.install!
      subject = session

      subject.get "/api/v1/posts"

      expect(subject.response.status).to eq(200)
      expect(JSON.parse(subject.response.body)).to eq("path" => "/api/v1/posts")
    end

    it "captures nothing once uninstalled" do
      source.install!
      source.uninstall!

      session.get "/api/v1/posts"

      expect(source.captured_count).to eq(0)
    end
  end

  # THE HARD PART. The recorder observes /api/v1/posts/42/comments, but the merge
  # key is (template, verb). Without reverse mapping, 200 requests against 200
  # posts become 200 separate "endpoints".
  describe "reverse-mapping a concrete path to its template" do
    it "recovers the template and keeps the concrete id alongside it" do
      payload = record { session.get "/api/v1/posts/42/comments" }

      recorded = payload["requests"].first
      expect(recorded["template"]).to eq("/api/v1/posts/{post_id}/comments")
      expect(recorded["path_values"]).to eq("post_id" => "42")
      expect(recorded["controller"]).to eq("api/v1/comments")
    end

    it "collapses many ids into one endpoint" do
      record do
        (1..50).each { |id| session.get "/api/v1/posts/#{id}" }
      end

      endpoints = source.endpoints(input_path: @output)

      expect(endpoints.length).to eq(1)
      expect(endpoints.first.path).to eq("/api/v1/posts/{id}")
    end

    it "keeps every distinct id it saw, as resolution source #2" do
      record { %w[7 8 9].each { |id| session.get "/api/v1/posts/#{id}" } }

      expect(source.endpoints(input_path: @output).first.recorded_path_values).to eq(id: %w[7 8 9])
    end

    it "handles a non-numeric segment" do
      payload = record { session.get "/api/v1/authors/ada-lovelace" }

      expect(payload["requests"].first["template"]).to eq("/api/v1/authors/{slug}")
      expect(payload["requests"].first["path_values"]).to eq("slug" => "ada-lovelace")
    end

    # Dropping it is the deliberate choice. Keeping the concrete path would
    # manufacture one endpoint per id, which is worse than a named gap.
    it "drops a path the router does not recognise, and counts it" do
      payload = record { session.get "/not/a/route/at/all" }

      expect(payload["requests"]).to be_empty
      expect(payload["unrecognised_count"]).to eq(1)
    end

    it "warns on read, so the report can name the coverage gap" do
      record { session.get "/not/a/route/at/all" }

      source.endpoints(input_path: @output)

      expect(source.warnings.join).to include("could not be mapped to a route template")
    end

    # WHICH ones, not just how many. An unmapped recording is the one "could not
    # measure" case that gets no row of its own in the report -- it is not in the
    # findings, the healthy list or the inconclusive list -- so a bare count leaves a
    # reader knowing coverage was lost and nothing about where.
    it "names the requests it could not map, so the warning is actionable" do
      record { session.get "/not/a/route/at/all" }

      source.endpoints(input_path: @output)

      expect(source.warnings.join).to include("GET /not/a/route/at/all")
    end

    it "reads an older recording that carries only the count" do
      record { session.get "/not/a/route/at/all" }
      payload = JSON.parse(File.read(@output))
      payload.delete("unrecognised_samples")
      File.write(@output, JSON.generate(payload))

      source.endpoints(input_path: @output)

      expect(source.warnings.join).to include("1 recorded request(s) could not be mapped")
    end
  end

  describe "what it captures" do
    it "records the verb, query params, and status" do
      payload = record { session.get "/api/v1/posts", params: { per_page: 25 } }

      recorded = payload["requests"].first
      expect(recorded["verb"]).to eq("get")
      expect(recorded["query"]).to eq("per_page" => "25")
      expect(recorded["status"]).to eq(200)
    end

    it "records a request body, which is why recording beats a drifted document" do
      payload = record do
        session.post "/api/v1/posts", params: { title: "Real", body: "Proven valid by a spec" }
      end

      expect(payload["requests"].first["body"]).to eq("title" => "Real", "body" => "Proven valid by a spec")
    end

    it "picks the richest recording when a template was hit several ways" do
      record do
        session.post "/api/v1/posts", params: { title: "thin" }
        session.post "/api/v1/posts", params: { title: "thick", body: "more", tags: %w[a b] }
      end

      endpoint = source.endpoints(input_path: @output).find { |e| e.verb == :post }

      expect(endpoint.request_body.keys).to include("title", "body", "tags")
    end
  end

  # Redaction at collection time, not render time. The recording file lives under
  # tmp/ and gets attached to bug reports; a token in it is a leak regardless of
  # what the report renders.
  describe "redaction" do
    it "filters an Authorization header" do
      payload = record do
        session.get "/api/v1/posts", headers: { "Authorization" => "Bearer sk-live-secret" }
      end

      serialised = JSON.generate(payload)
      expect(serialised).not_to include("sk-live-secret")
      expect(payload["requests"].first["headers"]["Authorization"]).to eq("[FILTERED]")
    end

    it "filters a sensitive parameter, nested included" do
      payload = record do
        session.post "/api/v1/posts", params: { title: "ok", user: { password: "hunter2" } }
      end

      expect(JSON.generate(payload)).not_to include("hunter2")
    end

    it "filters a token in a query string" do
      payload = record { session.get "/api/v1/posts", params: { api_key: "abc123" } }

      expect(JSON.generate(payload)).not_to include("abc123")
    end

    it "honours user-configured extra patterns" do
      config.redact_additional_patterns = [/account_number/i]

      payload = record { session.post "/api/v1/posts", params: { account_number: "4111111111111111" } }

      expect(JSON.generate(payload)).not_to include("4111111111111111")
    end
  end

  describe "reading the recording back" do
    it "returns nothing when nothing was ever recorded" do
      expect(source.endpoints(input_path: File.join(Dir.tmpdir, "nope.json"))).to eq([])
    end

    it "refuses a recording written by a different format version" do
      File.write(@output, JSON.generate("version" => 99, "requests" => []))

      expect { source.endpoints(input_path: @output) }
        .to raise_error(Loadwright::DiscoveryError, /different version of Loadwright/)
    end

    it "refuses an unreadable file rather than silently discovering nothing" do
      File.write(@output, "{not json")

      expect { source.endpoints(input_path: @output) }
        .to raise_error(Loadwright::DiscoveryError, /not readable JSON/)
    end

    it "marks endpoints as integration-spec sourced" do
      record { session.get "/api/v1/posts" }

      expect(source.endpoints(input_path: @output).first.sources).to eq([:integration_spec])
    end

    it "records the controller#action as the description" do
      record { session.get "/api/v1/posts" }

      expect(source.endpoints(input_path: @output).first.description).to eq("api/v1/posts#index")
    end
  end
end

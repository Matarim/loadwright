# frozen_string_literal: true

RSpec.describe Loadwright::Discovery::OpenapiSource do
  let(:config) { Loadwright::Configuration.new }

  def fixture(name) = File.join(SpecPaths::ROOT, "spec", "fixtures", "openapi", name)

  subject(:source) { described_class.new(config: config, stdout: StringIO.new) }

  describe "#endpoints" do
    before { config.openapi_spec_paths = [fixture("blog.yaml")] }

    it "produces one endpoint per path/operation pair" do
      expect(source.endpoints.map(&:to_s)).to contain_exactly(
        "GET /api/v1/posts",
        "POST /api/v1/posts",
        "GET /api/v1/posts/{id}/comments",
        "POST /api/v1/posts/{id}/comments"
      )
    end

    it "keys endpoints by path TEMPLATE, which is the merge key" do
      endpoint = source.endpoints.find { |e| e.verb == :get && e.path.include?("comments") }

      expect(endpoint.key).to eq(["/api/v1/posts/{id}/comments", :get])
    end

    it "records the operation id and summary" do
      endpoint = source.endpoints.find { |e| e.key == ["/api/v1/posts", :get] }

      expect(endpoint.operation_id).to eq("listPosts")
      expect(endpoint.description).to eq("List posts")
      expect(endpoint.sources).to eq([:openapi])
    end

    it "classifies verbs as mutating or safe" do
      by_key = source.endpoints.to_h { |e| [e.to_s, e.mutating?] }

      expect(by_key).to include("GET /api/v1/posts" => false, "POST /api/v1/posts" => true)
    end

    describe "path parameters" do
      it "collects them from both the template and the declared parameter list" do
        endpoint = source.endpoints.find { |e| e.key == ["/api/v1/posts/{id}/comments", :get] }

        expect(endpoint.path_params).to eq([:id])
        expect(endpoint).to be_path_params
      end

      # Declared on the path item rather than the operation — a shape real
      # documents use constantly, and one a naive walker misses entirely.
      it "picks up parameters declared once for the whole path item" do
        endpoint = source.endpoints.find { |e| e.key == ["/api/v1/posts/{id}/comments", :post] }

        expect(endpoint.path_params).to eq([:id])
      end
    end

    describe "query parameters" do
      it "records name, requiredness, type and example" do
        endpoint = source.endpoints.find { |e| e.key == ["/api/v1/posts", :get] }

        expect(endpoint.query_params).to contain_exactly(
          { name: "per_page", required: false, example: 25, type: "integer" },
          { name: "published", required: true, example: nil, type: "boolean" }
        )
      end
    end

    describe "request examples" do
      # A real example is always preferred: someone who knows the endpoint wrote
      # it. Synthesis is a fallback, not the primary path.
      it "prefers the document's own example over anything synthesised" do
        endpoint = source.endpoints.find { |e| e.key == ["/api/v1/posts", :post] }

        expect(endpoint.request_body).to eq("title" => "A real example", "body" => "from the document")
      end

      it "synthesises a body from the schema's required fields when no example exists" do
        endpoint = source.endpoints.find { |e| e.key == ["/api/v1/posts/{id}/comments", :post] }

        expect(endpoint.request_body).to eq("body" => "loadwright")
      end

      it "reports a mutating endpoint with no usable body as having no example" do
        no_body = Loadwright::Discovery::Endpoint.new(path: "/x", verb: :post, source: :openapi)

        expect(no_body).not_to be_example_available
      end
    end

    describe "response schemas" do
      # These feed the validity gate. A schema lifted out of its document could not
      # resolve $ref; keeping a pointer into the document means refs resolve
      # correctly, including into #/components/schemas.
      it "resolves $ref into components" do
        endpoint = source.endpoints.find { |e| e.key == ["/api/v1/posts", :get] }
        schema = endpoint.success_response_schema

        expect(schema.valid?([{ "id" => 1, "title" => "hello" }])).to be(true)
        expect(schema.valid?([{ "title" => "missing an id" }])).to be(false)
      end

      it "returns readable errors, since these land in a report" do
        schema = source.endpoints.find { |e| e.key == ["/api/v1/posts", :get] }.success_response_schema

        expect(schema.errors_for([{ "title" => "x" }]).join).to include("missing required properties: id")
      end

      # The trap avoided by not using openapi3_parser's node data, which injects
      # `additionalProperties: false`. Validating a real response against that would
      # reject any payload carrying a field the document did not enumerate — marking
      # healthy endpoints inconclusive for schema invalidity.
      it "does not reject a response carrying an undeclared extra field" do
        schema = source.endpoints.find { |e| e.key == ["/api/v1/posts", :get] }.success_response_schema

        expect(schema.valid?([{ "id" => 1, "title" => "x", "undocumented_field" => true }])).to be(true)
      end

      it "keeps the 2xx schema apart from the rest" do
        endpoint = source.endpoints.find { |e| e.key == ["/api/v1/posts", :post] }

        expect(endpoint.response_schemas.keys).to eq(["201"])
        expect(endpoint.success_status).to eq(201)
      end

      it "is nil when the document declares no schema for the operation" do
        endpoint = source.endpoints.find { |e| e.key == ["/api/v1/posts/{id}/comments", :post] }

        expect(endpoint.success_response_schema).to be_nil
      end
    end
  end

  # THE RULE THAT SHAPES THIS CLASS. A partial endpoint list is worse than none:
  # the endpoints it missed are reported as ABSENT rather than SKIPPED, and the
  # developer reads a clean report covering half their API.
  describe "failing loud on a partial parse" do
    it "refuses a document it cannot parse at all" do
      config.openapi_spec_paths = [fixture("unparseable.yaml")]

      expect { source.endpoints }.to raise_error(Loadwright::DiscoveryError, /not valid YAML\/JSON/)
    end

    it "refuses a structurally invalid document rather than returning what it read" do
      config.openapi_spec_paths = [fixture("malformed.yaml")]

      expect { source.endpoints }.to raise_error(Loadwright::DiscoveryError) { |error|
        expect(error.message).to include("could not be fully parsed")
        expect(error.message).to include("partial endpoint list is worse than none")
      }
    end

    # Verified against openapi3_parser 0.10.1 rather than assumed: it accepts a 3.1
    # version string but rejects 3.1-only constructs, and `document.paths` raises
    # rather than returning a partial read.
    it "names OpenAPI 3.1 as the likely cause when the document declares it" do
      config.openapi_spec_paths = [fixture("openapi_31.yaml")]

      expect { source.endpoints }.to raise_error(Loadwright::DiscoveryError) { |error|
        expect(error.message).to include("declares OpenAPI 3.1.0")
        expect(error.message).to include("webhooks")
        expect(error.message).to include("type arrays")
      }
    end

    it "lists every problem, not just the first" do
      config.openapi_spec_paths = [fixture("openapi_31.yaml")]

      expect { source.endpoints }.to raise_error(Loadwright::DiscoveryError) { |error|
        expect(error.message.scan(/^  - /).length).to be >= 2
      }
    end
  end

  describe "a missing document" do
    # Provenance decides. The default path is the rswag convention, which most apps
    # do not have — refusing over that would make the tool unusable out of the box.
    it "warns rather than raising when the path came from the default" do
      expect(config.provenance(:openapi_spec_paths)).to eq(:default)

      expect(source.endpoints).to be_empty
    end

    # But a path the USER wrote is a statement that the file is there. Silently
    # skipping it is how someone reads a four-endpoint report believing it covers
    # forty.
    it "raises when the user named the path explicitly" do
      config.openapi_spec_paths = ["/nope/swagger.yaml"]

      expect { source.endpoints }.to raise_error(Loadwright::DiscoveryError) { |error|
        expect(error.message).to include("does not exist")
        expect(error.message).to include("reported as absent rather than skipped")
      }
    end

    it "records the skip as a warning a report can surface" do
      config.openapi_spec_paths = [fixture("does-not-exist.yaml")]
      allow(config).to receive(:explicitly_set?).with(:openapi_spec_paths).and_return(false)

      source.endpoints

      expect(source.warnings.join).to include("skipping OpenAPI discovery")
    end
  end

  it "is a no-op with no documents configured" do
    config.openapi_spec_paths = []

    expect(source.endpoints).to eq([])
  end

  it "merges endpoints across several documents" do
    config.openapi_spec_paths = [fixture("blog.yaml"), fixture("blog.yaml")]

    expect(source.endpoints.length).to eq(8)
  end

  # THE REFUSAL IS RIGHT AND STAYS. What was missing is triage: an outside evaluation
  # hit 52 errors, saw 20 of them truncated to a terminal, and had no way to see the
  # rest or judge how much of the document was affected. Nobody fixes 52 errors they
  # cannot read, and that turned a fixable problem into a reason to stop evaluating.
  describe "when the document does not validate" do
    let(:broken) do
      <<~YAML
        openapi: 3.0.1
        info: { title: Broken, version: "1" }
        paths:
          /a:
            get:
              security:
                - Bearer: {}
              responses: { "200": { description: ok } }
          /b:
            get:
              responses: { "200": { description: ok } }
      YAML
    end

    around do |example|
      Dir.mktmpdir("openapi-errors-") do |dir|
        @dir = dir
        File.write(File.join(dir, "swagger.yaml"), broken)
        config.openapi_spec_paths = [File.join(dir, "swagger.yaml")]
        config.report_output_dir = dir
        example.run
      end
    end

    def failure
      described_class.new(config: config).endpoints
      nil
    rescue Loadwright::DiscoveryError => e
      e
    end

    it "still refuses, rather than discovering from half a document" do
      expect(failure).not_to be_nil
    end

    it "says how much of the document is affected, not just the first 20 errors" do
      expect(failure.message).to match(/error\(s\) across \d+ of \d+ path\(s\)/)
    end

    it "writes the full list somewhere it can be read" do
      failure

      report = JSON.parse(File.read(File.join(@dir, "openapi-errors.json")))
      expect(report["error_count"]).to be_positive
      expect(report["affected_paths"]).to include("/a")
      expect(report["errors"].length).to eq(report["error_count"])
    end

    # A team blocked on their document still has two working discovery sources, and
    # saying so is the difference between "fix this first" and "give up".
    it "names the discovery sources that need no document" do
      expect(failure.message).to include("loadwright record")
    end
  end
end

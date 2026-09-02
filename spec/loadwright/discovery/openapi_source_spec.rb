# frozen_string_literal: true

RSpec.describe Loadwright::Discovery::OpenapiSource do
  let(:config) { Loadwright::Configuration.new }

  def fixture(name) = File.join(SpecPaths::ROOT, "spec", "fixtures", "openapi", name)

  subject(:source) { described_class.new(config: config, stdout: StringIO.new) }

  # THE PATH IN AN OPENAPI DOCUMENT IS RELATIVE TO `servers`.
  #
  # An API mounted under a prefix may express it in either place -- in servers.url
  # with relative paths (the idiomatic form) or inlined into every path with a bare
  # host. Both are legal, and until 0.0.10 only the second worked, silently: every
  # operation in an idiomatic document landed under a path the app does not serve,
  # matched nothing, and was replaced by the same endpoint from a recording, which
  # carries no schema. So require_schema_valid_response was inert for the whole API
  # while every endpoint reported "no schema declared" as a fact about the API.
  describe "the server base path" do
    def write(body)
      dir = Dir.mktmpdir("openapi-servers-")
      path = File.join(dir, "swagger.yaml")
      File.write(path, body)
      config.openapi_spec_paths = [path]
      path
    end

    def doc(servers)
      <<~YAML
        openapi: "3.0.0"
        info: { title: t, version: "1" }
        #{servers}
        paths:
          /widgets/{id}:
            get:
              responses:
                "200": { description: ok }
      YAML
    end

    it "joins a relative server path onto every operation" do
      write(doc(%(servers:\n  - url: /internal/api)))

      expect(source.endpoints.map(&:to_s)).to eq(["GET /internal/api/widgets/{id}"])
    end

    it "takes only the path from a full server URL, never the host" do
      write(doc(%(servers:\n  - url: https://example.test/internal/api)))

      expect(source.endpoints.map(&:to_s)).to eq(["GET /internal/api/widgets/{id}"])
    end

    # The form that already worked, and must keep working: prefix inlined, bare host.
    it "adds nothing when the server declares no path" do
      write(doc(%(servers:\n  - url: https://example.test)))

      expect(source.endpoints.map(&:to_s)).to eq(["GET /widgets/{id}"])
    end

    it "adds nothing when there are no servers at all" do
      write(doc(""))

      expect(source.endpoints.map(&:to_s)).to eq(["GET /widgets/{id}"])
    end

    it "substitutes a server variable's default" do
      write(doc(%(servers:\n  - url: "/{stage}/api"\n    variables:\n      stage: { default: internal })))

      expect(source.endpoints.map(&:to_s)).to eq(["GET /internal/api/widgets/{id}"])
    end

    # A template with no default is unusable rather than guessable, and guessing would
    # put every operation under a prefix nobody serves.
    it "applies nothing for a template it cannot resolve" do
      write(doc(%(servers:\n  - url: "/{stage}/api")))

      expect(source.endpoints.map(&:to_s)).to eq(["GET /widgets/{id}"])
    end

    it "trims a trailing slash rather than doubling it" do
      write(doc(%(servers:\n  - url: /internal/api/)))

      expect(source.endpoints.map(&:to_s)).to eq(["GET /internal/api/widgets/{id}"])
    end

    # Two deployments, not two endpoints. Fabricating one per server would request
    # paths the app does not serve; picking one silently would put every operation
    # under a prefix half of them do not use. So: first wins, and say so.
    it "warns rather than choosing silently when servers disagree" do
      write(doc(%(servers:\n  - url: /internal/api\n  - url: /public/api)))

      endpoints = source.endpoints

      expect(endpoints.map(&:to_s)).to eq(["GET /internal/api/widgets/{id}"])
      expect(source.warnings.join).to include("different base paths", "/internal/api", "/public/api")
    end

    # Precedence is the specification's: operation over path item over root.
    it "lets an operation override the document's servers" do
      write(<<~YAML)
        openapi: "3.0.0"
        info: { title: t, version: "1" }
        servers:
          - url: /internal/api
        paths:
          /widgets/{id}:
            get:
              servers:
                - url: /special
              responses:
                "200": { description: ok }
      YAML

      expect(source.endpoints.map(&:to_s)).to eq(["GET /special/widgets/{id}"])
    end
  end

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
          { name: "per_page", required: false, example: 25, type: "integer", enum: [] },
          { name: "published", required: true, example: nil, type: "boolean", enum: [] }
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

  # ASK THE ENDPOINT WHAT IT ACCEPTS. A collection constraining its page size to a set
  # is common, and sweeping outside that set produces a client error the report then has
  # to explain -- an inconsistency the sweep itself created. It is declared right there
  # on the parameter, and nothing read it.
  describe "a page-size parameter that declares the values it accepts" do
    def endpoint_with(schema_extra)
      dir = Dir.mktmpdir("openapi-enum-")
      path = File.join(dir, "swagger.yaml")
      File.write(path, <<~YAML)
        openapi: "3.0.0"
        info: { title: t, version: "1" }
        paths:
          /widgets:
            get:
              parameters:
                - name: per_page
                  in: query
                  schema: { type: integer, #{schema_extra} }
              responses:
                "200": { description: ok }
      YAML
      config.openapi_spec_paths = [path]
      source.endpoints.first
    end

    it "captures the enum off the parameter" do
      expect(endpoint_with("enum: [10, 25, 50]").query_params.first[:enum]).to eq([10, 25, 50])
    end

    it "offers them as the sizes the sweep should use" do
      expect(endpoint_with("enum: [10, 25, 50]").declared_page_sizes(%w[per_page])).to eq([10, 25, 50])
    end

    # nil, not an empty array: the configured sweep stays the default when the document
    # declares nothing, and a caller must be able to tell those apart.
    it "declares nothing when the parameter has no enum" do
      expect(endpoint_with("default: 25").declared_page_sizes(%w[per_page])).to be_nil
    end

    it "declares nothing for a parameter name the run does not treat as a page size" do
      expect(endpoint_with("enum: [10, 25]").declared_page_sizes(%w[limit])).to be_nil
    end
  end
end

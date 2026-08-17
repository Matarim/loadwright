# frozen_string_literal: true

RSpec.describe Loadwright::Analysis::ResponseValidator do
  let(:config) { Loadwright::Configuration.new }

  subject(:validator) { described_class.new(config: config) }

  def endpoint(path: "/api/v1/posts", verb: :get, **rest)
    Loadwright::Discovery::Endpoint.new(path: path, verb: verb, source: :openapi, **rest)
  end

  def response(status: 200, body: "[]", error: nil, endpoint_for: nil)
    Loadwright::Execution::RawResponse.new(
      request: build_request(path: (endpoint_for || endpoint).path),
      status: status, headers: { "content-type" => "application/json" }, body: body, error: error
    )
  end

  # THE FAILURE THIS GATE EXISTS TO PREVENT. A 403 in 4ms with 1 query looks, to a
  # query-counting tool, like the healthiest endpoint in the API.
  describe "a failed status" do
    it "is inconclusive, not healthy" do
      verdict = validator.validate(endpoint: endpoint, response: response(status: 403, body: '{"error":"x"}'))

      expect(verdict).not_to be_valid
      expect(verdict.reason).to eq(:unsuccessful_status)
      expect(verdict.detail).to include("An error path was measured, not the endpoint")
    end

    it "maps to an EndpointOutcome that is excluded from the clean list" do
      verdict = validator.validate(endpoint: endpoint, response: response(status: 403))
      outcome = Loadwright::EndpointOutcome.inconclusive(
        endpoint: endpoint, reason: verdict.reason, detail: verdict.detail
      )

      expect(outcome).to be_inconclusive
      expect(outcome).not_to be_countable_as_clean
      expect(outcome.explanation).to include("an error path was measured")
    end

    # DIAG-01: the most common first-run failure by a wide margin.
    it "names auth as the likely cause for a 401 or 403" do
      [401, 403].each do |status|
        verdict = validator.validate(endpoint: endpoint, response: response(status: status))

        expect(verdict.detail).to include("auth_token_provider is unset or returning an invalid token")
      end
    end

    it "treats an escaped exception as a failed response" do
      verdict = validator.validate(
        endpoint: endpoint,
        response: response(status: nil, error: StandardError.new("connection reset"))
      )

      expect(verdict).not_to be_valid
      expect(verdict.detail).to include("connection reset")
    end

    it "accepts a status the document declares" do
      target = endpoint(expected_statuses: [204])
      verdict = validator.validate(endpoint: target, response: response(status: 204, body: nil))

      expect(verdict).to be_valid
    end

    it "still labels what it measured when the user relaxes the check" do
      config.require_successful_response = false

      verdict = validator.validate(endpoint: endpoint, response: response(status: 500, body: "[]"))

      expect(verdict).to be_valid
    end
  end

  # The other half of the same failure: an endpoint returning [] because the seeded
  # records missed its scope looks identical to a well-optimised one.
  describe "an empty response when data was seeded" do
    it "is inconclusive with the setup-problem reason" do
      verdict = validator.validate(endpoint: endpoint, response: response(body: "[]"), seeded_count: 200)

      expect(verdict).not_to be_valid
      expect(verdict.reason).to eq(:empty_with_seeded_data)
      expect(verdict.detail).to include("do not match the endpoint's scope")
      expect(verdict.detail).to include("published/draft flag")
      expect(verdict.detail).to include("factory trait")
    end

    it "is valid when nothing was seeded, since an empty collection is then correct" do
      expect(validator.validate(endpoint: endpoint, response: response(body: "[]"), seeded_count: 0))
        .to be_valid
    end

    it "is valid when nothing is known about seeding" do
      expect(validator.validate(endpoint: endpoint, response: response(body: "[]"))).to be_valid
    end

    it "is valid when the endpoint returned records" do
      expect(validator.validate(endpoint: endpoint, response: response(body: '[{"id":1}]'), seeded_count: 5))
        .to be_valid
    end
  end

  describe "schema validity" do
    # Built as nested literals rather than one deep expression: a schema pointer walks
    # this structure, so it has to be a real document shape.
    let(:item_schema) do
      { "type" => "object", "required" => %w[id title], "properties" => { "id" => { "type" => "integer" } } }
    end

    let(:media_type) { { "schema" => { "type" => "array", "items" => item_schema } } }

    let(:document) do
      {
        "paths" => {
          "/posts" => {
            "get" => {
              "responses" => { "200" => { "content" => { "application/json" => media_type } } }
            }
          }
        }
      }
    end

    let(:schema) do
      Loadwright::Discovery::SchemaRef.for(
        document: document,
        pointer: "#/paths/~1posts/get/responses/200/content/application~1json/schema"
      )
    end

    let(:target) { endpoint(response_schemas: { "200" => schema }) }

    it "passes a conforming response" do
      expect(validator.validate(endpoint: target, response: response(body: '[{"id":1,"title":"x"}]')))
        .to be_valid
    end

    it "is inconclusive with the specific schema error" do
      verdict = validator.validate(endpoint: target, response: response(body: '[{"title":"no id"}]'))

      expect(verdict.reason).to eq(:schema_invalid)
      expect(verdict.detail).to include("missing required properties: id")
      expect(verdict.schema_errors).not_to be_empty
    end

    it "measures anyway when the user relaxes the check, but records the errors" do
      config.require_schema_valid_response = false

      verdict = validator.validate(endpoint: target, response: response(body: '[{"title":"no id"}]'))

      expect(verdict).to be_valid
      expect(verdict.schema_errors).not_to be_empty
    end

    # Gated on schema validity only "when a schema exists for that operation".
    it "skips the check entirely when no schema is declared" do
      verdict = validator.validate(endpoint: endpoint, response: response(body: '[{"anything":true}]'))

      expect(verdict).to be_valid
      expect(verdict.schema_errors).to be_nil
    end
  end

  describe "counting records" do
    # The count must agree exactly with the correlator's, since it is the denominator
    # of queries-per-returned-record.
    it "counts a bare array" do
      expect(validator.count_records(JSON.parse('[{"id":1},{"id":2}]'))).to eq(2)
    end

    %w[data results items records rows entries collection].each do |key|
      it "counts a collection wrapped in #{key.inspect}" do
        expect(validator.count_records(JSON.parse(%({"#{key}":[{"id":1}],"meta":{}})))).to eq(1)
      end
    end

    it "counts a collection under the resource name from the path" do
      parsed = JSON.parse('{"posts":[{"id":1},{"id":2},{"id":3}],"total":3}')

      expect(validator.count_records(parsed, endpoint(path: "/api/v1/posts"))).to eq(3)
    end

    # Reporting 0 records for a `show` endpoint would make every one of them look
    # empty and trip the seeded-data check.
    it "is nil for a single-object response, not zero" do
      expect(validator.count_records(JSON.parse('{"id":1,"title":"x"}'))).to be_nil
    end

    it "is nil for an unparseable body" do
      verdict = validator.validate(endpoint: endpoint, response: response(body: "<html>oops</html>"))

      expect(verdict.record_count).to be_nil
    end
  end

  describe "cross-scale shape consistency" do
    # If the structure changes between scale factors, comparing across them is invalid
    # and the slope means nothing.
    it "accepts one consistent shape" do
      expect(validator.consistent_shape?(["array(id,title)", "array(id,title)"])).to be(true)
    end

    it "rejects differing shapes and names them" do
      shapes = ["array(id,title)", "object(data,meta)"]

      expect(validator.consistent_shape?(shapes)).to be(false)
      expect(validator.shape_inconsistency_detail(shapes)).to include("2 distinct shapes")
      expect(validator.shape_inconsistency_detail(shapes)).to include("cross-scale comparison is not valid")
    end

    it "ignores cells that produced no shape at all" do
      expect(validator.consistent_shape?(["array(id)", nil, "array(id)"])).to be(true)
    end

    describe "the fingerprint" do
      it "is shallow, so an absent optional nested field is not a shape change" do
        first = validator.fingerprint(JSON.parse('[{"id":1,"author":{"name":"a"}}]'))
        second = validator.fingerprint(JSON.parse('[{"id":1,"author":null}]'))

        expect(first).to eq(second)
      end

      it "distinguishes an array from an envelope" do
        expect(validator.fingerprint(JSON.parse("[]"))).to eq("array(empty)")
        expect(validator.fingerprint(JSON.parse('{"data":[]}'))).to eq("object(data)")
      end

      it "is key-order independent" do
        expect(validator.fingerprint(JSON.parse('[{"b":1,"a":2}]')))
          .to eq(validator.fingerprint(JSON.parse('[{"a":2,"b":1}]')))
      end
    end
  end

  # The live fixture, because the 403 endpoint is the one this whole gate exists for
  # and a mock of it proves nothing about the real app.
  describe "against the fixture app", :sample_app do
    let(:session) do
      require "action_dispatch/testing/integration"
      ActionDispatch::Integration::Session.new(sample_app)
    end

    def real_response(path)
      session.get path
      Loadwright::Execution::RawResponse.new(
        request: build_request(path: path),
        status: session.response.status,
        headers: session.response.headers,
        body: session.response.body
      )
    end

    it "marks the always-403 endpoint inconclusive rather than fastest-in-the-API" do
      verdict = validator.validate(
        endpoint: endpoint(path: "/api/v1/admin/stats"),
        response: real_response("/api/v1/admin/stats")
      )

      expect(verdict).not_to be_valid
      expect(verdict.reason).to eq(:unsuccessful_status)
    end

    it "marks a scope mismatch inconclusive: draft posts seeded, published-only endpoint" do
      FactoryBot.create_list(:post, 10, :draft)

      verdict = validator.validate(
        endpoint: endpoint(path: "/api/v1/posts"),
        response: real_response("/api/v1/posts"),
        seeded_count: 10
      )

      expect(verdict.reason).to eq(:empty_with_seeded_data)
    end

    it "validates a genuinely working endpoint" do
      FactoryBot.create_list(:post, 5, :with_comments)

      verdict = validator.validate(
        endpoint: endpoint(path: "/api/v1/posts"),
        response: real_response("/api/v1/posts"),
        seeded_count: 5
      )

      expect(verdict).to be_valid
      expect(verdict.record_count).to eq(5)
      expect(verdict.body_bytes).to be > 0
    end
  end
end

# frozen_string_literal: true

RSpec.describe Loadwright::Discovery::Endpoint do
  def endpoint(**overrides)
    described_class.new(**{ path: "/api/v1/posts", verb: :get, source: :openapi }.merge(overrides))
  end

  describe "the merge key" do
    # Keyed by TEMPLATE, not concrete path. The OpenAPI document says
    # /posts/{id}/comments while recording observes /posts/42/comments — without a
    # shared key the two sources never merge and the endpoint appears twice with
    # half the information each.
    it "is the (path template, verb) pair" do
      expect(endpoint(path: "/api/v1/posts/{id}", verb: :patch).key).to eq(["/api/v1/posts/{id}", :patch])
    end

    it "normalises a Rails template into the OpenAPI form, so both sources agree" do
      expect(described_class.normalize_path("/api/v1/posts/:id/comments(.:format)"))
        .to eq("/api/v1/posts/{id}/comments")
    end

    it "reads path params from either form" do
      expect(described_class.params_in("/posts/{post_id}/comments/{id}")).to eq(%w[post_id id])
      expect(described_class.params_in("/posts/:post_id/comments/:id")).to eq(%w[post_id id])
    end
  end

  describe "#example_available?" do
    # discovery-and-load-engine.md: route-discovered endpoints with no example are
    # reported as "discovered but no example available; skipped", never guessed at.
    it "is true for a safe verb, which needs no body" do
      expect(endpoint(verb: :get, source: :route)).to be_example_available
    end

    it "is false for a mutating verb with no body and no recording" do
      expect(endpoint(verb: :post, source: :route)).not_to be_example_available
    end

    it "is true for a mutating verb with a documented body" do
      expect(endpoint(verb: :post, request_body: { "title" => "x" })).to be_example_available
    end

    it "is true for a mutating verb that a spec actually exercised" do
      expect(endpoint(verb: :post, source: :integration_spec)).to be_example_available
    end
  end

  describe "#merge" do
    let(:documented) do
      endpoint(
        path: "/api/v1/posts/{id}", verb: :patch, source: :openapi,
        operation_id: "updatePost",
        request_body: { "title" => "loadwright" },
        response_schemas: { "200" => :a_schema },
        query_params: [{ name: "expand", example: nil }],
        expected_statuses: [200, 422]
      )
    end

    let(:recorded) do
      endpoint(
        path: "/api/v1/posts/{id}", verb: :patch, source: :integration_spec,
        request_body: { "title" => "a title a spec actually sent", "tags" => %w[a b] },
        query_params: [{ name: "expand", example: "author" }],
        recorded_path_values: { id: %w[42 43] },
        expected_statuses: [200],
        description: "posts#update"
      )
    end

    # Integration-spec data is proven-valid and often richer than a document that
    # has drifted. That is the whole reason for having two sources.
    it "prefers the recorded request body over the documented one" do
      merged = documented.merge(recorded)

      expect(merged.request_body).to eq("title" => "a title a spec actually sent", "tags" => %w[a b])
    end

    it "prefers recorded query examples, which are real values" do
      expect(documented.merge(recorded).query_params.first[:example]).to eq("author")
    end

    # Recording cannot produce a schema; only the document can. Losing it would
    # disable the validity gate for every endpoint a spec happens to cover.
    it "keeps the documented response schema, which recording cannot produce" do
      expect(documented.merge(recorded).response_schemas).to eq("200" => :a_schema)
    end

    it "records both sources" do
      expect(documented.merge(recorded).sources).to contain_exactly(:openapi, :integration_spec)
    end

    it "carries the recorded concrete ids through, for path-param resolution" do
      expect(documented.merge(recorded).recorded_path_values).to eq(id: %w[42 43])
    end

    it "unions the expected statuses" do
      expect(documented.merge(recorded).expected_statuses).to contain_exactly(200, 422)
    end

    # Merge order must not change the outcome, because sources arrive in whatever
    # order the run configured them.
    it "is order-independent for every field that matters" do
      forwards = documented.merge(recorded)
      backwards = recorded.merge(documented)

      expect(backwards.request_body).to eq(forwards.request_body)
      expect(backwards.response_schemas).to eq(forwards.response_schemas)
      expect(backwards.recorded_path_values).to eq(forwards.recorded_path_values)
      expect(backwards.sources.sort).to eq(forwards.sources.sort)
    end

    it "refuses to merge two different endpoints" do
      expect { documented.merge(endpoint(path: "/other", verb: :get)) }
        .to raise_error(ArgumentError, /cannot merge/)
    end
  end

  describe "#success_response_schema" do
    it "picks the 2xx schema and ignores error schemas" do
      subject = endpoint(response_schemas: { "404" => :not_found, "200" => :ok, "500" => :error })

      expect(subject.success_response_schema).to eq(:ok)
    end

    # A doc declaring only error responses gets nil, not a guess — the validity
    # gate only applies "when a schema exists for that operation".
    it "is nil when only error responses are declared" do
      expect(endpoint(response_schemas: { "404" => :not_found }).success_response_schema).to be_nil
    end
  end

  describe "#success_status" do
    it "prefers a declared 2xx" do
      expect(endpoint(expected_statuses: [422, 201]).success_status).to eq(201)
    end

    it "falls back to 200 for a safe verb and 201 for a mutating one" do
      expect(endpoint(verb: :get).success_status).to eq(200)
      expect(endpoint(verb: :post).success_status).to eq(201)
    end
  end

  it "derives path params from the template when none are declared" do
    expect(endpoint(path: "/posts/{post_id}/comments/{id}", source: :route).path_params)
      .to eq(%i[post_id id])
  end

  it "requires a source, so no endpoint has unknown provenance" do
    expect { described_class.new(path: "/x", verb: :get) }
      .to raise_error(ArgumentError, /must record where it came from/)
  end

  it "rejects an unknown source" do
    expect { described_class.new(path: "/x", verb: :get, source: :vibes) }
      .to raise_error(ArgumentError, /unknown endpoint source/)
  end

  it "is frozen" do
    expect(endpoint).to be_frozen
  end
end

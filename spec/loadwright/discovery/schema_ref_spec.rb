# frozen_string_literal: true

RSpec.describe Loadwright::Discovery::SchemaRef do
  # A real OpenAPI path template, which is the whole point: nearly every operation
  # worth measuring has a path parameter.
  let(:document) do
    {
      "paths" => {
        "/api/v1/widgets/{id}" => {
          "get" => {
            "responses" => {
              "200" => {
                "content" => {
                  "application/json" => {
                    "schema" => { "type" => "object", "required" => ["id"],
                                  "properties" => { "id" => { "type" => "integer" } } }
                  }
                }
              }
            }
          }
        }
      }
    }
  end

  let(:pointer) do
    "#/paths/~1api~1v1~1widgets~1{id}/get/responses/200/content/application~1json/schema"
  end

  subject(:ref) { described_class.for(document: document, pointer: pointer) }

  # A JSON POINTER IS NOT A URI FRAGMENT UNTIL IT IS ESCAPED, and json_schemer takes a
  # URI. `{` and `}` are illegal in a fragment unescaped, so URI() raised on every
  # operation with a path parameter -- which is most of them.
  #
  # The raise was not the damage. It was rescued and returned as an ERROR STRING, so a
  # fault inside this gem reached the user as "response did not validate against its
  # declared OpenAPI schema": twenty endpoints told their responses were invalid on the
  # strength of a check that never executed, and three correctly-measured N+1 findings
  # discarded with them, because a schema violation disqualifies an endpoint.
  describe "a path template in the pointer" do
    it "resolves rather than raising on the braces" do
      expect(ref.resolution_error).to be_nil
      expect(ref).to be_resolvable
    end

    it "actually validates against the resolved schema" do
      expect(ref.errors_for("id" => 1)).to be_empty
      expect(ref.errors_for("name" => "x")).not_to be_empty
    end

    it "escapes only what a fragment forbids, leaving the pointer's own syntax alone" do
      escaped = described_class.escape_fragment(pointer)

      expect(escaped).to include("%7Bid%7D")
      # `~1` is the JSON-pointer escape for `/`, and both are legal in a fragment.
      # Re-escaping either breaks resolution the other way.
      expect(escaped).to include("~1api~1v1")
      expect(escaped).to start_with("#/paths/")
    end

    it "leaves a pointer with no path parameter untouched" do
      plain = "#/paths/~1api~1v1~1widgets/get"

      expect(described_class.escape_fragment(plain)).to eq(plain)
    end
  end

  # THE TWO FACTS MUST NOT SHARE A RETURN VALUE. "Your response is wrong" and "we could
  # not load the schema" are opposite, and folding the second into the first is what
  # made a one-line escaping bug look like twenty broken endpoints.
  describe "a schema that cannot be loaded" do
    let(:document) { { "paths" => {} } }
    let(:pointer) { "#/paths/~1nope/get/responses/200/schema" }

    subject(:ref) { described_class.new(document: document, pointer: pointer) }

    it "raises rather than returning the failure as a validation error" do
      expect { ref.errors_for({}) }.to raise_error(described_class::ResolutionError)
    end

    it "reports the reason without raising, for the disclosure" do
      expect(ref.resolution_error).to be_a(String)
      expect(ref).not_to be_resolvable
    end
  end
end

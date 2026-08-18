# frozen_string_literal: true

require "openapi3_parser"

# THE CONTRACT WITH openapi3_parser, asserted so a gem upgrade fails loudly here rather
# than silently degrading response validation somewhere downstream.
#
# Loadwright uses this gem as the authority on whether a document is well-formed, and
# then reads schemas out of the RAW parsed hash rather than out of the parser's nodes.
# That is deliberate — Node::Schema#to_h is shallow and injects
# `additionalProperties: false`, and validating a real response against that would
# reject any payload carrying a field the document did not enumerate, marking healthy
# endpoints schema-invalid. See SchemaRef.
#
# The cost of that choice is a dependency on things that are not public API. These
# examples pin each one. If any fails after a bump, the fix is to look at what changed
# before trusting the validation again — NOT to relax the expectation.
RSpec.describe "the openapi3_parser contract" do
  def fixture(name) = File.join(SpecPaths::ROOT, "spec", "fixtures", "openapi", name)

  let(:document) { Openapi3Parser.load_file(fixture("blog.yaml")) }

  it "is a version this gem was verified against" do
    expect(Gem.loaded_specs.fetch("openapi3_parser").version.to_s)
      .to match(/\A0\.10\./), "openapi3_parser was bumped past the verified range; re-verify this file"
  end

  describe "what Loadwright relies on" do
    it "reports validity as a boolean, which is the gate discovery uses" do
      expect(document.valid?).to be(true)
      expect(Openapi3Parser.load_file(fixture("openapi_31.yaml")).valid?).to be(false)
    end

    # Without the location, a document's worth of problems reads as
    # "Invalid type. Expected String" with nothing to point at.
    it "gives each validation error a message and a JSON-pointer context" do
      error = Openapi3Parser.load_file(fixture("openapi_31.yaml")).errors.to_a.first

      expect(error).to respond_to(:message)
      expect(error).to respond_to(:context)
      expect(error.message).to be_a(String)
      expect(error.context.to_s).to start_with("#/")
    end
  end

  # The reasons for NOT using the parser's node data. If either of these ever stops
  # being true, the raw-hash detour can be reconsidered — but only deliberately.
  describe "why the raw hash is used instead of Node::Schema#to_h" do
    let(:schema) do
      document.paths["/api/v1/posts"].get.responses["200"].content["application/json"].schema
    end

    it "is shallow: nested schemas come back as node objects, not hashes" do
      expect(schema.to_h["items"]).not_to be_a(Hash)
    end

    # The dangerous one. A JSON Schema validator handed this rejects any response with
    # a field the document did not enumerate.
    it "injects additionalProperties: false, which would reject valid responses" do
      expect(schema.to_h).to include("additionalProperties" => false)
    end
  end

  # The 3.1 findings, re-asserted against the installed gem so a version that gains 3.1
  # support is noticed rather than assumed absent.
  describe "the 3.1 boundary" do
    it "accepts a 3.1 version string on otherwise-3.0 content" do
      expect(Openapi3Parser.load_file(fixture("openapi_31_compatible.yaml")).valid?).to be(true)
    end

    it "still rejects 3.1-only constructs" do
      errors = Openapi3Parser.load_file(fixture("openapi_31.yaml")).errors.to_a.map(&:message).join(" ")

      expect(errors).to match(/Unexpected fields.*webhooks|Invalid type/)
    end
  end
end

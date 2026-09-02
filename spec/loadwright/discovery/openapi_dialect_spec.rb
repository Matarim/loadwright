# frozen_string_literal: true

RSpec.describe Loadwright::Discovery::OpenapiDialect do
  def validate(document, payload, pointer: "#/components/schemas/Widget")
    require "json_schemer"
    translated = described_class.translate(document).document
    JSONSchemer.schema(translated).ref(pointer).validate(payload).map { |e| e["error"] || e.to_s }
  end

  def doc(properties, extra_schemas = {})
    { "openapi" => "3.0.1",
      "components" => { "schemas" => {
        "Widget" => { "type" => "object", "properties" => properties }
      }.merge(extra_schemas) } }
  end

  # `nullable: true` IS AN OPENAPI 3.0 EXTENSION AND NOT A JSON SCHEMA KEYWORD, so a
  # bare JSON Schema validator discards it and `type: string` then rejects null. Every
  # property a document legitimately declares nullable produced a violation on every
  # response where it was null -- and because a schema violation disqualifies an
  # endpoint, a real hand-verified N+1 sat suppressed for three rounds behind a defect
  # that did not exist.
  describe "nullable" do
    it "lets a declared-nullable property be null" do
      errors = validate(doc("closed_on" => { "type" => "string", "nullable" => true }),
                        { "closed_on" => nil })

      expect(errors).to be_empty
    end

    it "still rejects the wrong type when the value is not null" do
      errors = validate(doc("amount" => { "type" => "integer", "nullable" => true }),
                        { "amount" => "not-an-integer" })

      expect(errors).not_to be_empty
    end

    it "leaves a property that is not nullable alone" do
      errors = validate(doc("amount" => { "type" => "integer" }), { "amount" => nil })

      expect(errors).not_to be_empty
    end

    # THE TRAP THAT MAKES A PARTIAL FIX LOOK LIKE A WORKING ONE. `$ref`s resolve against
    # the document ROOT, so a nullable schema reached through one is invisible to a
    # translation scoped to the subtree a pointer resolves to. On a real document that
    # cleared three of four violations and left the fourth.
    it "reaches a nullable schema through a $ref" do
      errors = validate(
        doc({ "buyer" => { "$ref" => "#/components/schemas/Buyer" } },
            "Buyer" => { "type" => "object", "nullable" => true,
                         "properties" => { "id" => { "type" => "integer" } } }),
        { "buyer" => nil }
      )

      expect(errors).to be_empty
    end

    # A `$ref` IGNORES ITS SIBLINGS, so widening a type next to one does nothing -- the
    # union has to be expressed around the reference itself.
    it "handles nullable declared beside a $ref rather than on the target" do
      errors = validate(
        doc({ "buyer" => { "$ref" => "#/components/schemas/Buyer", "nullable" => true } },
            "Buyer" => { "type" => "object", "properties" => { "id" => { "type" => "integer" } } }),
        { "buyer" => nil }
      )

      expect(errors).to be_empty
    end

    # An enum constrains the value directly; a type union beside it would still reject
    # nil, because nil is not in the list.
    it "admits null to a nullable enum" do
      errors = validate(doc("state" => { "type" => "string", "enum" => %w[open closed],
                                         "nullable" => true }),
                        { "state" => nil })

      expect(errors).to be_empty
    end

    # `required` applies only to objects in JSON Schema, so it is correctly ignored when
    # the value is null -- worth pinning, because it is the obvious thing to fear.
    it "does not apply a nullable object's required list to null" do
      errors = validate(doc("buyer" => { "type" => "object", "nullable" => true,
                                         "required" => ["id"],
                                         "properties" => { "id" => { "type" => "integer" } } }),
                        { "buyer" => nil })

      expect(errors).to be_empty
    end

    it "does not mutate the document it was given" do
      original = doc("closed_on" => { "type" => "string", "nullable" => true })
      described_class.translate(original)

      expect(original.dig("components", "schemas", "Widget", "properties", "closed_on"))
        .to eq("type" => "string", "nullable" => true)
    end

    it "reports which keywords it translated" do
      result = described_class.translate(doc("a" => { "type" => "string", "nullable" => true }))

      expect(result.translated_keywords).to include("nullable")
      expect(result).to be_changed
    end
  end

  # In 3.0 these are BOOLEAN modifiers on minimum/maximum; in the dialect json_schemer
  # speaks they are numbers in their own right.
  describe "the 3.0 boolean form of exclusiveMinimum" do
    it "rewrites it to the numeric form" do
      translated = described_class.translate(
        doc("n" => { "type" => "integer", "minimum" => 5, "exclusiveMinimum" => true })
      ).document

      expect(translated.dig("components", "schemas", "Widget", "properties", "n"))
        .to eq("type" => "integer", "exclusiveMinimum" => 5)
    end

    it "drops the flag when it says the bound is inclusive" do
      translated = described_class.translate(
        doc("n" => { "type" => "integer", "minimum" => 5, "exclusiveMinimum" => false })
      ).document

      expect(translated.dig("components", "schemas", "Widget", "properties", "n"))
        .to eq("type" => "integer", "minimum" => 5)
    end

    it "leaves the 2020-12 numeric form alone" do
      translated = described_class.translate(
        doc("n" => { "type" => "integer", "exclusiveMinimum" => 5 })
      ).document

      expect(translated.dig("components", "schemas", "Widget", "properties", "n"))
        .to eq("type" => "integer", "exclusiveMinimum" => 5)
    end
  end

  # Annotations cannot cause a valid payload to be rejected, so they are NAMED rather
  # than translated -- rewriting them would be inventing meaning we cannot verify.
  describe "keywords it deliberately does not translate" do
    it "names a discriminator rather than acting on it" do
      result = described_class.translate(
        doc("a" => { "type" => "string" }).merge("discriminator" => { "propertyName" => "kind" })
      )

      expect(result.annotations).to include("discriminator")
      expect(result.translated_keywords).to be_empty
    end
  end
end

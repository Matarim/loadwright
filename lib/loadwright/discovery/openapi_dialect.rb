# frozen_string_literal: true

module Loadwright
  module Discovery
    # Translates an OpenAPI 3.0 document into the JSON Schema dialect the validator
    # actually speaks.
    #
    # WHY THIS EXISTS, AND WHY IT IS THE WORST BUG THIS PROJECT HAS SHIPPED.
    #
    # `SchemaRef` hands the raw document to json_schemer, which is a JSON SCHEMA
    # validator. `nullable: true` is an OpenAPI 3.0 EXTENSION and is not a JSON Schema
    # keyword, so it was silently discarded -- and `type: string` then rejects `null`.
    # Every property a document legitimately declares nullable produced a violation on
    # every response where that property was null.
    #
    # The cost was not the false errors. A schema violation disqualifies an endpoint, so
    # a real, hand-verified N+1 sat suppressed for three rounds behind a defect that did
    # not exist -- and the user, reading a confident report, wrote down that the fault
    # was theirs and invented a plausible mechanism to explain it. **Every schema
    # violation ever reported against that API was false.** A tool that reports a defect
    # on the user's side is believed; that is exactly what makes a false positive
    # aimed at their code the most expensive kind of wrong answer this tool can give.
    #
    # THE TRANSLATION IS DOCUMENT-WIDE, NOT SUBTREE-SCOPED, and that distinction is
    # load-bearing. `$ref`s resolve against the document ROOT -- which is the documented
    # reason SchemaRef stores (document, pointer) rather than an extracted hash -- so a
    # nullable schema reached THROUGH a `$ref` is invisible to a fix scoped to the
    # resolved subtree. Measured against a real document: translating the subtree
    # cleared three of four violations and left the fourth, which looks exactly like a
    # working fix and is not.
    module OpenapiDialect
      # 3.0 keywords that change what a payload is allowed to be, and that json_schemer
      # will not honour. Translated below.
      TRANSLATED = %w[nullable exclusiveMinimum exclusiveMaximum].freeze

      # 3.0-isms that are ANNOTATIONS. They do not cause a valid payload to be rejected,
      # so they are reported rather than translated -- naming them is honest, and
      # rewriting them would be inventing meaning we cannot verify.
      ANNOTATIONS = %w[discriminator xml example externalDocs].freeze

      Result = Struct.new(:document, :translated_keywords, :annotations, keyword_init: true) do
        def changed? = translated_keywords.any?
      end

      # Returns a Result carrying a NEW document; the input is never mutated, because
      # the caller also reads the raw document for paths, parameters and statuses and
      # must keep seeing what the author wrote.
      def self.translate(document)
        seen = Hash.new(0)
        translated = walk(document, seen)

        Result.new(
          document: translated,
          translated_keywords: seen.keys.select { |k| TRANSLATED.include?(k) }.sort,
          annotations: seen.keys.select { |k| ANNOTATIONS.include?(k) }.sort
        )
      end

      def self.walk(node, seen)
        return node.map { |item| walk(item, seen) } if node.is_a?(Array)
        return node unless node.is_a?(Hash)

        mapped = node.to_h { |key, value| [key, walk(value, seen)] }
        ANNOTATIONS.each { |key| seen[key] += 1 if mapped.key?(key) }

        mapped = widen_nullable(mapped, seen)
        exclusive_bounds(mapped, seen)
      end

      # Four shapes, because `nullable` sits next to four different things and the right
      # translation differs for each.
      def self.widen_nullable(node, seen)
        return node unless node["nullable"] == true

        seen["nullable"] += 1
        widened = node.reject { |key, _| key == "nullable" }

        # A `$ref` IGNORES ITS SIBLINGS, so widening a type next to one does nothing.
        # The union has to be expressed around the reference itself.
        if widened.key?("$ref")
          rest = widened.reject { |key, _| key == "$ref" }
          return rest.merge("anyOf" => [{ "$ref" => widened["$ref"] }, { "type" => "null" }])
        end

        # An enum constrains the value directly; a type union next to it would still
        # reject nil because nil is not in the list.
        widened["enum"] = (widened["enum"] + [nil]).uniq if widened["enum"].is_a?(Array)

        return widened unless widened.key?("type")

        widened.merge("type" => (Array(widened["type"]) + ["null"]).uniq)
      end

      # In 3.0 these are BOOLEAN modifiers on `minimum`/`maximum`; in the dialect
      # json_schemer speaks they are numbers in their own right. Left as booleans they
      # are meaningless at best and a schema error at worst.
      def self.exclusive_bounds(node, seen)
        result = node

        { "exclusiveMinimum" => "minimum", "exclusiveMaximum" => "maximum" }.each do |flag, bound|
          value = result[flag]
          next unless value == true || value == false

          seen[flag] += 1
          result = result.reject { |key, _| key == flag }
          # `false` means "the bound is inclusive", which is what the bare bound already
          # says -- so the flag is simply dropped.
          result = result.reject { |key, _| key == bound }.merge(flag => result[bound]) if
            value == true && result.key?(bound)
        end

        result
      end

      private_class_method :walk, :widen_nullable, :exclusive_bounds
    end
  end
end

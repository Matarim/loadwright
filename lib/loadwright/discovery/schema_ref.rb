# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Discovery
    # A pointer into an OpenAPI document, resolvable into a JSON Schema validator.
    #
    # WHY A POINTER RATHER THAN AN EXTRACTED HASH. Schemas in a real document are
    # full of `$ref`s into `#/components/schemas`, and a schema lifted out of its
    # document loses the ability to resolve them. json_schemer resolves refs
    # against the document root, so what gets stored is (document, JSON pointer)
    # and the validator is built from the root — refs resolve for free and
    # correctly, including recursive ones.
    #
    # WHY NOT openapi3_parser's OWN NODE DATA. That was the obvious route and it is
    # wrong. `Node::Schema#to_h` is shallow — nested schemas come back as node
    # objects rather than hashes — and it injects every OpenAPI default, including
    # `additionalProperties: false`. Validating a real response against that
    # rejects any payload with a field the doc did not enumerate, which would mark
    # perfectly healthy endpoints `inconclusive` for schema invalidity. So
    # openapi3_parser validates the document, and the raw parsed document carries
    # the schemas.
    class SchemaRef
      attr_reader :pointer

      def initialize(document:, pointer:)
        @document = document
        @pointer = pointer
      end

      # nil when the document declares no schema for this operation — which is not
      # an error. response-analysis.md gates on schema validity only "when a schema
      # exists for that operation".
      def self.for(document:, pointer:)
        node = resolve(document, pointer)
        return nil if node.nil?

        new(document: document, pointer: pointer)
      end

      def self.resolve(document, pointer)
        pointer.delete_prefix("#/").split("/").reduce(document) do |node, segment|
          return nil unless node.is_a?(Hash)

          node[segment.gsub("~1", "/").gsub("~0", "~")]
        end
      end

      def validator
        @validator ||= begin
          require "json_schemer"
          JSONSchemer.schema(@document).ref(@pointer)
        end
      end

      # Returns an array of human-readable error strings; empty means valid. Strings
      # rather than objects because these go straight into a report, and a
      # developer needs "object at `/0` is missing required properties: id", not a
      # schema traversal.
      def errors_for(payload)
        validator.validate(payload).map { |error| error["error"] || error.to_s }
      rescue StandardError => e
        ["schema could not be applied (#{e.class}: #{e.message})"]
      end

      def valid?(payload) = errors_for(payload).empty?

      def to_h = { pointer: pointer }
    end
  end
end

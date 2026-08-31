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
      # A schema we could not LOAD, which is never a statement about the response.
      ResolutionError = Class.new(Loadwright::Error)

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

      # A JSON POINTER IS NOT A URI FRAGMENT UNTIL IT IS ESCAPED, and json_schemer takes
      # a URI. An OpenAPI path template contains `{` and `}`, which are illegal in a
      # fragment unescaped, so `URI()` raised on every operation that has a path
      # parameter -- which is most of them.
      #
      # The damage was not the raise. `errors_for` rescued it and returned it as an
      # ERROR STRING, so a resolution failure inside this gem was reported to the user
      # as "response did not validate against its declared OpenAPI schema": twenty
      # endpoints told they had invalid responses on the strength of a check that never
      # executed, and three correctly-measured N+1 findings discarded as collateral,
      # because a schema violation disqualifies an endpoint. See `resolution_error`
      # below -- the two are now different facts with different sentences.
      #
      # Escapes only what a fragment forbids. `/` and `~` are legal and load-bearing
      # here: `~1` is the JSON-pointer escape for `/`, and re-escaping either would
      # break resolution the other way.
      FRAGMENT_SAFE = %r{[^A-Za-z0-9\-._~!$&'()*+,;=:@/?]}

      def self.escape_fragment(pointer)
        body = pointer.to_s.delete_prefix("#")

        "##{body.gsub(FRAGMENT_SAFE) { |char| format('%%%02X', char.ord) }}"
      end

      def validator
        @validator ||= begin
          require "json_schemer"
          JSONSchemer.schema(@document).ref(self.class.escape_fragment(@pointer))
        end
      end

      # Returns an array of human-readable error strings; empty means valid. Strings
      # rather than objects because these go straight into a report, and a
      # developer needs "object at `/0` is missing required properties: id", not a
      # schema traversal.
      #
      # RAISES ON A RESOLUTION FAILURE rather than returning one as an error string.
      # Those are opposite facts -- "your response is wrong" and "we could not load the
      # schema" -- and folding the second into the first is what let a one-line
      # escaping bug be reported as twenty endpoints with invalid responses. The caller
      # separates them; this refuses to blur them.
      def errors_for(payload)
        validator.validate(payload).map { |error| error["error"] || error.to_s }
      rescue StandardError => e
        raise ResolutionError, "#{e.class}: #{e.message}"
      end

      # nil when the schema resolves, a reason when it does not. Lets a caller ask the
      # question without an exception, for the disclosure that has to say which of the
      # two happened.
      def resolution_error
        validator
        nil
      rescue StandardError => e
        "#{e.class}: #{e.message}"
      end

      def resolvable? = resolution_error.nil?

      def valid?(payload) = errors_for(payload).empty?

      def to_h = { pointer: pointer }
    end
  end
end

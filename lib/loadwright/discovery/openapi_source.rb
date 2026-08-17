# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Discovery
    # Parses OpenAPI/Swagger via openapi3_parser.
    #
    # A document that cannot be fully parsed must fail LOUDLY at discovery rather
    # than yielding a partial endpoint list — a silently short list reports
    # endpoints as absent rather than skipped, telling a developer their API is
    # clean when half of it was never looked at.
    #
    # Specified in references/discovery-and-load-engine.md
    #
    # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
    class OpenapiSource
      def endpoints(*, **, &)
        raise NotImplementedError, "Loadwright::Discovery::OpenapiSource#endpoints is not implemented yet"
      end
    end
  end
end

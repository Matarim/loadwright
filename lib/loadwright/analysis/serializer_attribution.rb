# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Analysis
    # Points an N+1 at the serializer or template it originates in. Serializer-level
    # N+1s are the most commonly missed kind in API apps because the controller
    # looks clean.
    #
    # Specified in references/response-analysis.md (Part 5)
    #
    # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
    class SerializerAttribution
      def attribute(*, **, &)
        raise NotImplementedError, "Loadwright::Analysis::SerializerAttribution#attribute is not implemented yet"
      end
    end
  end
end

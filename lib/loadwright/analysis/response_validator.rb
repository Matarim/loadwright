# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Analysis
    # The validity gate, run before any performance signal is computed: success
    # status, schema validity, non-empty when seeding implies non-empty, and a
    # consistent shape across scale factors. Any failure means :inconclusive with a
    # named reason — never a performance verdict.
    #
    # Specified in references/response-analysis.md (Part 1)
    #
    # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
    class ResponseValidator
      def validate(*, **, &)
        raise NotImplementedError, "Loadwright::Analysis::ResponseValidator#validate is not implemented yet"
      end
    end
  end
end

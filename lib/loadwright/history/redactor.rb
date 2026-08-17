# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module History
    # Sanitises at COLLECTION time, not render time, so secrets never reach the
    # persisted run record either.
    #
    # Specified in references/reporting.md
    #
    # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
    class Redactor
      def redact(*, **, &)
        raise NotImplementedError, "Loadwright::History::Redactor#redact is not implemented yet"
      end
    end
  end
end

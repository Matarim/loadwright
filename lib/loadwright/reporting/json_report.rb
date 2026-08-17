# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Reporting
    # Raw structured data for external tooling.
    #
    # Specified in references/reporting.md
    #
    # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
    class JsonReport
      def render(*, **, &)
        raise NotImplementedError, "Loadwright::Reporting::JsonReport#render is not implemented yet"
      end
    end
  end
end

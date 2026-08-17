# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Reporting
    # New findings, resolved findings, changed magnitude, within-noise changes,
    # and state transitions.
    #
    # Specified in references/run-comparison.md
    #
    # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
    class ComparisonReport
      def render(*, **, &)
        raise NotImplementedError, "Loadwright::Reporting::ComparisonReport#render is not implemented yet"
      end
    end
  end
end

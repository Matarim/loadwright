# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module History
    # Comparability gate first: refuse and name the diverging dimension rather
    # than produce a plausible meaningless delta. Query counts are the primary
    # signal; latency deltas must clear both regression_threshold_pct and the
    # measured noise floor. A healthy -> inconclusive transition is neither a fix
    # nor a regression and must be surfaced as its own event.
    #
    # Specified in references/run-comparison.md
    #
    # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
    class Comparator
      def compare(*, **, &)
        raise NotImplementedError, "Loadwright::History::Comparator#compare is not implemented yet"
      end
    end
  end
end

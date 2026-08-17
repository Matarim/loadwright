# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Analysis
    # Percentiles, sample counts and coefficient of variation. A percentile the
    # sample size cannot support is OMITTED with the required N stated, not printed
    # with a caveat.
    #
    # Specified in references/performance-signals.md (Part 5)
    #
    # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
    class Statistics
      def percentiles(*, **, &)
        raise NotImplementedError, "Loadwright::Analysis::Statistics#percentiles is not implemented yet"
      end
    end
  end
end

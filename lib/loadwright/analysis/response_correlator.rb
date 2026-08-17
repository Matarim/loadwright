# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Analysis
    # Queries per RETURNED record, over-fetch hints, and payload growth. Slope is
    # measured against returned record count, not seeded count: a paginated
    # endpoint returns one page whether you seed 10 rows or 10,000, so seed-based
    # slope looks perfect while a severe N+1 sits on the page it returns.
    # Endpoints whose result size cannot be varied are flagged 'N+1 slope not
    # measurable', never 'flat'.
    #
    # Specified in references/response-analysis.md (Parts 2-4)
    #
    # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
    class ResponseCorrelator
      def correlate(*, **, &)
        raise NotImplementedError, "Loadwright::Analysis::ResponseCorrelator#correlate is not implemented yet"
      end
    end
  end
end

# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Analysis
    # Runs after the load phase, never during it.
    #
    # EXPLAIN ANALYZE EXECUTES THE STATEMENT. ANALYZE is used on SELECT only;
    # everything else gets plain EXPLAIN. When in doubt, plain EXPLAIN wins.
    #
    # Specified in references/performance-signals.md (Part 2)
    #
    # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
    class ExplainAnalyzer
      def analyze(*, **, &)
        raise NotImplementedError, "Loadwright::Analysis::ExplainAnalyzer#analyze is not implemented yet"
      end
    end
  end
end

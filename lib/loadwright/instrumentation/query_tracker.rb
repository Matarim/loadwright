# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Instrumentation
    # Query counts, fingerprints and duplicate detection off sql.active_record, in
    # the manner of Bullet and Prosopite. Disables the AR query cache during a run:
    # it dedupes identical queries within a request and will hide a textbook N+1
    # completely.
    #
    # Specified in references/discovery-and-load-engine.md
    #
    # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
    class QueryTracker
      def start!(*, **, &)
        raise NotImplementedError, "Loadwright::Instrumentation::QueryTracker#start! is not implemented yet"
      end

      def stop!(*, **, &)
        raise NotImplementedError, "Loadwright::Instrumentation::QueryTracker#stop! is not implemented yet"
      end

      def metrics(*, **, &)
        raise NotImplementedError, "Loadwright::Instrumentation::QueryTracker#metrics is not implemented yet"
      end
    end
  end
end

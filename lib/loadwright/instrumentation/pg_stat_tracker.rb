# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Instrumentation
    # pg_stat_statements sampling. Postgres only; degrades to unavailable
    # elsewhere rather than reporting nothing.
    #
    # Specified in references/performance-signals.md
    #
    # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
    class PgStatTracker
      def start!(*, **, &)
        raise NotImplementedError, "Loadwright::Instrumentation::PgStatTracker#start! is not implemented yet"
      end

      def stop!(*, **, &)
        raise NotImplementedError, "Loadwright::Instrumentation::PgStatTracker#stop! is not implemented yet"
      end

      def metrics(*, **, &)
        raise NotImplementedError, "Loadwright::Instrumentation::PgStatTracker#metrics is not implemented yet"
      end
    end
  end
end

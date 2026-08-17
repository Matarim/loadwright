# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module History
    # Persists run records (git SHA, branch, dirty flag, resolved config, mode,
    # machine fingerprint, per-endpoint outcomes), pruned to run_history_limit.
    #
    # Specified in references/run-comparison.md
    #
    # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
    class RunStore
      def write!(*, **, &)
        raise NotImplementedError, "Loadwright::History::RunStore#write! is not implemented yet"
      end

      def list(*, **, &)
        raise NotImplementedError, "Loadwright::History::RunStore#list is not implemented yet"
      end

      def prune!(*, **, &)
        raise NotImplementedError, "Loadwright::History::RunStore#prune! is not implemented yet"
      end
    end
  end
end

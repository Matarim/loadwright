# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Analysis
    # Flags threads x workers > AR pool size even when no contention was observed —
    # it is a latent problem and stating it costs nothing.
    #
    # Specified in references/performance-signals.md (Part 4)
    #
    # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
    class PoolSizingCheck
      def check(*, **, &)
        raise NotImplementedError, "Loadwright::Analysis::PoolSizingCheck#check is not implemented yet"
      end
    end
  end
end

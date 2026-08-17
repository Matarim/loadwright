# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Seeding
    # Rotates across several authenticated identities. Single-identity traffic
    # gives identical cache keys and single-tenant scoping, which can make a badly
    # scoped query look fine.
    #
    # Specified in references/performance-signals.md (Part 6)
    #
    # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
    class IdentityPool
      def next_identity(*, **, &)
        raise NotImplementedError, "Loadwright::Seeding::IdentityPool#next_identity is not implemented yet"
      end
    end
  end
end

# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Execution
    # Boots a server, allocates a port, polls until healthy, tears down. Registers
    # its teardown with Lifecycle rather than trapping signals itself.
    #
    # Specified in references/execution-modes.md
    #
    # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
    class ServerManager
      def boot!(*, **, &)
        raise NotImplementedError, "Loadwright::Execution::ServerManager#boot! is not implemented yet"
      end

      def teardown!(*, **, &)
        raise NotImplementedError, "Loadwright::Execution::ServerManager#teardown! is not implemented yet"
      end
    end
  end
end

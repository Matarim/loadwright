# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Execution
    module Transport
      # ActionDispatch::Integration::Session in the harness process. Zero setup,
      # perfect attribution, no real concurrency.
      #
      # Specified in references/execution-modes.md (Mode A)
      #
      # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
      class InProcess
        def issue(*, **, &)
          raise NotImplementedError, "Loadwright::Execution::Transport::InProcess#issue is not implemented yet"
        end
      end
    end
  end
end

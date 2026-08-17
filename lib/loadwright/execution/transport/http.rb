# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Execution
    module Transport
      # Real HTTP against a booted or already-running server. Real threads, real
      # queueing, real client-observed latency.
      #
      # Specified in references/execution-modes.md (Mode B)
      #
      # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
      class Http
        def issue(*, **, &)
          raise NotImplementedError, "Loadwright::Execution::Transport::Http#issue is not implemented yet"
        end
      end
    end
  end
end

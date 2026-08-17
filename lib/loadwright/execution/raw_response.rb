# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Execution
    # What a transport returns: status, headers, body, wall-clock latency, request
    # id. Transport-independent by construction.
    #
    # Specified in references/execution-modes.md
    #
    # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
    class RawResponse
      # Not implemented yet.
    end
  end
end

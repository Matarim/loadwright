# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Execution
    module Transport
      # How a request is issued. Returns a RawResponse and knows nothing about
      # instrumentation — that is the collector's job. Splitting the two is what
      # lets an :http run against a remote target report reduced capability rather
      # than wrong numbers.
      #
      # Specified in references/execution-modes.md
      #
      # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
      class Base
        def issue(*, **, &)
          raise NotImplementedError, "Loadwright::Execution::Transport::Base#issue is not implemented yet"
        end
      end
    end
  end
end

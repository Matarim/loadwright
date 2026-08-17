# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Execution
    module Transport
      # Issues nothing; replays scripted responses. Exists so the analysis pipeline,
      # resource guard and reporting are testable without booting Rails or opening a
      # socket. Also backs --dry-run.
      #
      # Specified in references/execution-modes.md
      #
      # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
      class Null
        def issue(*, **, &)
          raise NotImplementedError, "Loadwright::Execution::Transport::Null#issue is not implemented yet"
        end
      end
    end
  end
end

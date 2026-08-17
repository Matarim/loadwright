# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Execution
    module Collector
      # Reads ActiveSupport::Notifications, ObjectSpace, GC.stat and the connection
      # pool directly, because the harness shares the app's process.
      #
      # Specified in references/execution-modes.md (Mode A)
      #
      # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
      class Direct
        def collect(*, **, &)
          raise NotImplementedError, "Loadwright::Execution::Collector::Direct#collect is not implemented yet"
        end

        def capabilities(*, **, &)
          raise NotImplementedError, "Loadwright::Execution::Collector::Direct#capabilities is not implemented yet"
        end
      end
    end
  end
end

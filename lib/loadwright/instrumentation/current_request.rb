# frozen_string_literal: true

module Loadwright
  module Instrumentation
    # The one place the current request id is read from and written to.
    #
    # Extracted because more than one subscriber needs it — sql.active_record for
    # query attribution and process_action.action_controller for the time breakdown
    # — and two copies of "which request is this event for?" is exactly the kind of
    # duplication that drifts into two different answers under concurrency.
    #
    # ActiveSupport::IsolatedExecutionState rather than a hand-rolled fiber or thread
    # local: it honours the host app's configured isolation_level, and getting
    # isolation subtly wrong here would be undetectable — the numbers would simply
    # belong to a different request. This is why the gem's floor is Rails 7.0.
    module CurrentRequest
      KEY = :loadwright_request_id

      module_function

      def id
        require "active_support/isolated_execution_state"
        ::ActiveSupport::IsolatedExecutionState[KEY]
      rescue StandardError
        nil
      end

      def id=(value)
        require "active_support/isolated_execution_state"
        ::ActiveSupport::IsolatedExecutionState[KEY] = value
      end

      def clear! = self.id = nil

      # Scopes a block to a request id and restores whatever was set before, so a
      # nested instrumented call cannot orphan the outer request's attribution.
      def with(request_id)
        previous = id
        self.id = request_id
        yield
      ensure
        self.id = previous
      end
    end
  end
end

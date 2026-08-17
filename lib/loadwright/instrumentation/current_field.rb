# frozen_string_literal: true

module Loadwright
  module Instrumentation
    # The GraphQL field currently being resolved, for query attribution.
    #
    # Same mechanism and same reasoning as CurrentRequest: IsolatedExecutionState
    # honours the host app's isolation_level, and getting isolation wrong here would
    # attribute a query to the wrong resolver rather than fail visibly.
    #
    # A STACK, because field resolution nests: `posts.comments.author` is three
    # frames deep and a query issued there belongs to the innermost one.
    module CurrentField
      KEY = :loadwright_field_stack

      module_function

      def stack
        require "active_support/isolated_execution_state"
        ::ActiveSupport::IsolatedExecutionState[KEY] ||= []
      rescue StandardError
        []
      end

      # The innermost field, as a dotted path: "Query.authors.postCount".
      def path
        frames = stack
        frames.empty? ? nil : frames.join(".")
      end

      def with(field_name)
        frames = stack
        frames.push(field_name)
        yield
      ensure
        frames.pop
      end

      def clear!
        require "active_support/isolated_execution_state"
        ::ActiveSupport::IsolatedExecutionState[KEY] = []
      rescue StandardError
        nil
      end
    end
  end
end

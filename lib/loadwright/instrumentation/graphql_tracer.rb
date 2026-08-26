# frozen_string_literal: true

module Loadwright
  module Instrumentation
    # Attributes queries to the RESOLVER that issued them, not just the operation.
    #
    # Without this a GraphQL finding names the operation, which for a query of any
    # size is "somewhere in here". The resolver is the thing you go and fix.
    #
    # Installed by the host app on its own schema:
    #
    #   class MySchema < GraphQL::Schema
    #     trace_with Loadwright::Instrumentation::GraphqlTracer
    #   end
    #
    # It is a no-op unless a run is in progress, so leaving it in place costs a
    # host app nothing outside a Loadwright run.
    module GraphqlTracer
      def execute_field(field:, query:, ast_node:, arguments:, object:)
        return super unless Loadwright::Instrumentation::CurrentRequest.id

        Loadwright::Instrumentation::CurrentField.with(field_label(field)) { super }
      end

      # Lazy fields resolve AFTER their enclosing frame has unwound, which is exactly
      # where a batched loader does its work -- so without tracing this too, the
      # queries a lazy resolver issues would land on whatever happened to be on the
      # stack, or on nothing at all.
      def execute_field_lazy(field:, query:, ast_node:, arguments:, object:)
        return super unless Loadwright::Instrumentation::CurrentRequest.id

        Loadwright::Instrumentation::CurrentField.with(field_label(field)) { super }
      end

      private

      # "Author.postCount" -- the owner type plus the field, which is what a developer
      # searches for. `path` on the query would give the response path including list
      # indices ("authors.0.postCount"), which differs per record and would make every
      # repeated query look distinct.
      def field_label(field)
        owner = field.owner&.graphql_name
        owner ? "#{owner}.#{field.graphql_name}" : field.graphql_name
      rescue StandardError
        nil
      end
    end
  end
end

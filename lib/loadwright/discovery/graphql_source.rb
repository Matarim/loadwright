# frozen_string_literal: true

module Loadwright
  module Discovery
    # Discovers GraphQL OPERATIONS: every one is a POST to the same path, so
    # path-based discovery would report a whole API as a single row.
    #
    # Operations come from documents on disk or a list in the initializer, never from
    # schema introspection -- a generated query measures traffic the app never
    # receives.
    #
    # Remaining gap: a finding names the operation, not the resolver inside it.
    class GraphqlSource
      # `query Name(...)` / `mutation Name(...)` / `subscription Name`
      OPERATION_NAME = /\A\s*(?:query|mutation|subscription)\s+([A-Za-z_][A-Za-z0-9_]*)/m
      OPERATION_TYPE = /\A\s*(query|mutation|subscription)\b/m
      VARIABLE = /\$([A-Za-z_][A-Za-z0-9_]*)/

      def initialize(config: Loadwright.configuration, stdout: $stdout)
        @config = config
        @stdout = stdout
        @warnings = []
      end

      attr_reader :warnings

      def self.configured?(config) = !config.graphql_path.nil?

      def endpoints
        return [] unless self.class.configured?(@config)

        operations = inline_operations + file_operations
        if operations.empty?
          @warnings << "graphql_path is set but no operations were found. Add graphql_operations, " \
                       "or point graphql_document_paths at your .graphql files — Loadwright will not " \
                       "invent queries from your schema, because generated queries measure traffic " \
                       "your app never receives."
          return []
        end

        operations.filter_map { |operation| build_endpoint(operation) }
      end

      private

      def inline_operations
        Array(@config.graphql_operations).map { |operation| symbolize(operation) }
      end

      # A .graphql file is one document; its operation name comes from the document
      # itself, falling back to the filename, which is what most codebases name it
      # after anyway.
      def file_operations
        Array(@config.graphql_document_paths).flat_map { |glob| Dir.glob(glob.to_s) }.sort.filter_map do |path|
          document = File.read(path)
          name = OPERATION_NAME.match(document)&.captures&.first || File.basename(path, ".*")
          { name: name, query: document }
        rescue StandardError => e
          @warnings << "could not read the GraphQL document at #{path} (#{e.class}: #{e.message})"
          nil
        end
      end

      def build_endpoint(operation)
        name = operation[:name] || OPERATION_NAME.match(operation[:query].to_s)&.captures&.first
        if name.nil? || operation[:query].to_s.strip.empty?
          @warnings << "skipping a GraphQL operation with no query, or with no name that could be " \
                       "determined: #{operation.inspect}"
          return nil
        end

        type = operation_type(operation)
        if type == :subscription
          @warnings << "skipping the GraphQL subscription #{name}: subscriptions are not answered " \
                       "over a plain HTTP POST, so there is nothing here to measure."
          return nil
        end

        Endpoint.new(
          path: @config.graphql_path,
          verb: :post,
          source: :graphql,
          graphql_operation: name,
          # Decides `mutating?`, and therefore whether allow_mutating_requests applies.
          # A GraphQL query is a read that happens to travel by POST.
          graphql_operation_type: type,
          graphql_page_size_variable: page_size_variable(operation),
          # The body a client would post. Variables are the user's, verbatim: a
          # generated variable is a value nobody asks for.
          request_body: { "query" => operation[:query], "variables" => operation[:variables] || {},
                          "operationName" => name },
          description: operation[:description]
        )
      end

      # The variable the page-size sweep varies. Taken from the document's declared
      # variables first, since that is what the server will accept, falling back to
      # the supplied variables hash.
      def page_size_variable(operation)
        return operation[:page_size_variable].to_s if operation[:page_size_variable]

        candidates = Array(@config.graphql_page_size_variables).map(&:to_s)
        declared = operation[:query].to_s.scan(VARIABLE).flatten
        supplied = symbolize_keys_to_s(operation[:variables]).keys

        (declared & candidates).first || (supplied & candidates).first
      end

      def symbolize_keys_to_s(hash)
        (hash || {}).to_h { |key, value| [key.to_s, value] }
      end

      # An unnamed document (`{ posts { id } }`) is a query by definition -- the spec
      # only allows the shorthand form for queries.
      def operation_type(operation)
        return operation[:type].to_sym if operation[:type]

        (OPERATION_TYPE.match(operation[:query].to_s)&.captures&.first || "query").to_sym
      end

      def symbolize(hash)
        (hash || {}).to_h { |key, value| [key.to_s.to_sym, value] }
      end
    end
  end
end

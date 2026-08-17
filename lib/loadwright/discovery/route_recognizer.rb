# frozen_string_literal: true

require "loadwright/discovery/endpoint"

module Loadwright
  module Discovery
    # Reverse-maps a concrete request path back to the route template that matched
    # it.
    #
    # THIS IS THE HARD PART OF INTEGRATION-SPEC RECORDING, not the interception.
    # The recorder observes `/api/v1/posts/42/comments`, but the merge key is
    # `(path_template, verb)` — so without this, a recorded request never merges
    # with its OpenAPI counterpart, and worse, 200 requests against 200 different
    # post ids become 200 separate "endpoints" in the report.
    #
    # Uses the router's own recognition rather than pattern-matching paths against
    # route regexps by hand, so globs, constraints, format segments and mounted
    # engines all behave the way the app behaves.
    class RouteRecognizer
      Recognition = Struct.new(:template, :path_values, :controller, :action, keyword_init: true)

      def initialize(routes: nil)
        @routes = routes
      end

      def available? = !router.nil?

      # Returns a Recognition, or nil when the router does not recognise the path.
      # nil is a real answer, not a failure to be papered over: the caller drops the
      # recording and reports the count, because keeping the concrete path would
      # manufacture one endpoint per id.
      def recognize(verb, path)
        return nil unless available?

        request = build_request(verb, path)
        return nil if request.nil?

        router.recognize(request) do |route, params|
          next if route.nil?

          return Recognition.new(
            template: Endpoint.normalize_path(route.path.spec.to_s),
            path_values: extract_path_values(route, params),
            controller: params[:controller],
            action: params[:action]
          )
        end

        nil
      rescue StandardError
        # Router internals differ across Rails versions; an unrecognised path and a
        # recognition that blew up are the same outcome for the caller, and neither
        # justifies taking the run down.
        nil
      end

      private

      def router
        @router ||= begin
          routes = @routes || (defined?(::Rails) && ::Rails.respond_to?(:application) &&
                               ::Rails.application&.routes)
          routes&.router
        end
      end

      def build_request(verb, path)
        require "action_dispatch"
        require "rack/mock_request"

        env = Rack::MockRequest.env_for(path, method: verb.to_s.upcase)
        ::ActionDispatch::Request.new(env)
      rescue StandardError
        nil
      end

      # Only the dynamic segments, and only as they appeared. These are resolution
      # order #2 for path params — real ids that demonstrably worked in a spec.
      def extract_path_values(route, params)
        names = Endpoint.params_in(route.path.spec.to_s).map(&:to_sym)

        names.each_with_object({}) do |name, out|
          value = params[name]
          out[name] = value unless value.nil?
        end
      end
    end
  end
end

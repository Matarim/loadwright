# frozen_string_literal: true

require "loadwright/discovery/endpoint"

module Loadwright
  module Discovery
    # Rails route introspection. GAP-FILLING ONLY.
    #
    # A route knows a path and a verb and nothing else — no example body, no schema,
    # no idea what a valid request looks like. So endpoints from here are the lowest
    # fidelity available, and discovery-and-load-engine.md is explicit about what to
    # do with them: flag them as "discovered but no example available; skipped"
    # rather than guessing at a request.
    #
    # The value is coverage honesty. Without route discovery, an endpoint absent from
    # both the OpenAPI document and the request specs simply does not appear in the
    # report, and the reader has no way to know it was never considered. With it, the
    # report can say "and 14 endpoints exist that neither source describes."
    class RouteSource
      # Rails' own internal routes. Exercising these measures Rails, not the app.
      INTERNAL_CONTROLLERS = %w[
        rails/info rails/welcome rails/mailers rails/conductor
        active_storage action_mailbox turbo
      ].freeze

      def initialize(config: Loadwright.configuration, routes: nil)
        @config = config
        @routes = routes
      end

      def available? = !route_set.nil?

      def endpoints
        return [] unless @config.route_discovery
        return [] unless available?

        route_set.routes.flat_map { |route| endpoints_for(route) }.compact.uniq(&:key)
      end

      private

      def route_set
        @route_set ||= @routes ||
                       (defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application&.routes) ||
                       nil
      end

      def endpoints_for(route)
        return [] if internal?(route)

        template = Endpoint.normalize_path(route.path.spec.to_s)
        return [] if template.empty?

        verbs_for(route).map do |verb|
          Endpoint.new(
            path: template,
            verb: verb,
            source: :route,
            description: route_description(route)
          )
        end
      end

      # A route with no verb constraint answers everything. Expanding it to all seven
      # would manufacture six endpoints that do not exist; GET is the honest
      # single guess, and the endpoint is low-fidelity by construction anyway.
      def verbs_for(route)
        constraint = route.verb
        matched = constraint.to_s.scan(/GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS/).uniq

        return [:get] if matched.empty?

        matched.map { |verb| verb.downcase.to_sym }
      end

      def internal?(route)
        controller = route.defaults[:controller].to_s
        return true if controller.empty? && route.defaults[:action].to_s.empty?

        INTERNAL_CONTROLLERS.any? { |prefix| controller.start_with?(prefix) }
      end

      def route_description(route)
        controller = route.defaults[:controller]
        action = route.defaults[:action]
        return nil unless controller

        "#{controller}##{action}"
      end
    end
  end
end

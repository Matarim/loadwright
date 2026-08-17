# frozen_string_literal: true

require "action_controller"
require "action_dispatch"

# A real ActionDispatch::Routing::RouteSet, so route discovery and the recorder's
# reverse mapping are tested against the router the app actually uses.
#
# Hand-building a fake that "returns templates" would test nothing: the reverse
# mapping's whole job is to agree with Rails about which route matched, including
# constraints, globs, format segments and nested resources — none of which a fake
# reproduces.
module RoutingHelpers
  def build_route_set(&block)
    ActionDispatch::Routing::RouteSet.new.tap { |set| set.draw(&block) }
  end

  # The shape a real API app has: nested resources, a member action, a
  # non-numeric id, and a couple of things that should be filtered out.
  def blog_route_set
    build_route_set do
      namespace :api do
        namespace :v1 do
          resources :posts, only: %i[index show create update destroy] do
            resources :comments, only: %i[index create]
            member { post :publish }
          end
          get "authors/:slug", to: "authors#show"
        end
      end
      get "health", to: "health#show"
      get "rails/info/properties", to: "rails/info#properties"
    end
  end
end

RSpec.configure { |c| c.include RoutingHelpers }

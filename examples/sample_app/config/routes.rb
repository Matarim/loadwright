# frozen_string_literal: true

SampleApp::Application.routes.draw do
  namespace :api do
    namespace :v1 do
      resources :posts, only: %i[index show create] do
        resources :comments, only: %i[index]
      end
      resources :authors, only: %i[index show]
      resources :tags, only: %i[index]
      get "authors/by-slug/:slug", to: "authors#by_slug", as: :author_by_slug
      get "me", to: "me#show"
      post "login", to: "sessions#create"
      post "graphql", to: "graphql#create"
      post "gql", to: "gql#create"
      namespace :admin do
        get "stats", to: "stats#show"
      end
    end
  end
end

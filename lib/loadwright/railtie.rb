# frozen_string_literal: true

require "rails/railtie"
require "loadwright/execution/collector_middleware"
require "loadwright/execution/identity_endpoint"

module Loadwright
  # Rails integration point.
  #
  # This railtie deliberately does almost nothing on load. Two things must never
  # happen here:
  #
  #   1. ACTIVATING the collector middleware. execution-modes.md requires it be
  #      active only while a guard-approved run is in progress — it exposes SQL,
  #      call sites and timing. The Rack entry is inserted at boot because Rails'
  #      middleware stack is frozen after initialization and cannot be modified
  #      mid-run; the entry is INERT until CollectorMiddleware.mount! is called,
  #      and goes inert again on unmount!. Inserting a dormant pass-through and
  #      arming it separately is the only way to satisfy both constraints.
  #
  #   2. Touching the database or reading configuration at boot. The initializer
  #      in the host app is evaluated in every environment, including production
  #      (which is why the generated file carries the `if defined?(Loadwright)`
  #      guard), so boot-time work here would run where the gem must be inert.
  #
  # The identity endpoint (production-safety.md Layer 1b) is genuinely mounted
  # here, unconditionally. That is correct rather than an oversight: it is
  # unguarded by design, returns only the environment name, gem version, and
  # enabled flag, and its presence in a production process is itself the signal
  # the remote-target check is looking for. If the gem is not loaded in
  # production, the endpoint is not there.
  class Railtie < ::Rails::Railtie
    initializer "loadwright.identity_endpoint" do |app|
      app.middleware.insert_before 0, Execution::IdentityEndpoint
    end

    initializer "loadwright.collector_middleware" do |app|
      app.middleware.use Execution::CollectorMiddleware
    end

    generators do
      require "generators/loadwright/install_generator"
    end
  end
end

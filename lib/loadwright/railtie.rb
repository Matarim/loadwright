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

    # ARMING THE MIDDLEWARE IN A BOOTED CHILD PROCESS.
    #
    # In :http mode the app under test is a DIFFERENT process, so nothing in the
    # harness can call CollectorMiddleware.mount! there — and without that the
    # middleware stays dormant, the collector degrades to External, and every
    # query-derived finding comes back unavailable. The run would work and say almost
    # nothing.
    #
    # So ServerManager passes the per-run secret to the child in its environment, and
    # the child arms itself here. Note what this is NOT: the secret's presence is not
    # authorisation. mount! still asks the guard, and still refuses in a
    # production-adjacent environment regardless of what the environment variable says
    # — which matters, because an environment variable is exactly the kind of thing
    # that gets left set.
    initializer "loadwright.arm_collector" do
      secret = ENV.fetch("LOADWRIGHT_COLLECTOR_SECRET", nil)

      unless secret.to_s.empty?
        config.after_initialize do
          tracker = Instrumentation::QueryTracker.new(config: Loadwright.configuration)
          tracker.start!

          begin
            Execution::CollectorMiddleware.mount!(
              tracker: tracker,
              guard: Safety::EnvironmentGuard.new(config: Loadwright.configuration),
              secret: secret
            )
          rescue SafetyError => e
            # Not fatal for the app under test: it simply serves requests without
            # instrumentation, and the harness sees the missing correlation headers and
            # degrades its own capability honestly.
            warn "loadwright: not arming the collector middleware — #{e.message}"
            tracker.stop!
          end
        end
      end
    end

    generators do
      require "generators/loadwright/install_generator"
    end
  end
end

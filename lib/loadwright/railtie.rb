# frozen_string_literal: true

require "rails/railtie"
require "loadwright/execution/server_manager"
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
    # So ServerManager writes the per-run secret to a mode-0600 file and passes the
    # PATH in the child's environment; the child reads it here. The secret itself never
    # travels in an environment variable, because an environment block is readable by
    # any local user through `ps` and lands in crash dumps and spawn logs — and this
    # secret guards an endpoint serving SQL and call sites from the app under test.
    #
    # Note what the file's presence is NOT: authorisation. mount! still asks the guard
    # and still refuses in a production-adjacent environment regardless of what is on
    # disk — which matters, because a path in an environment variable is exactly the
    # kind of thing that gets left set.
    initializer "loadwright.arm_collector" do
      # The run id is checked against the file's contents, so a secret left behind by a
      # run that was SIGKILLed cannot arm a later process that happens to point at it.
      secret = Execution::ServerManager.read_secret_file(
        ENV.fetch(Execution::ServerManager::SECRET_FILE_VARIABLE, nil),
        ENV.fetch(Execution::ServerManager::SECRET_RUN_ID_VARIABLE, nil)
      )

      unless secret.to_s.empty?
        config.after_initialize do
          tracker = Instrumentation::QueryTracker.new(config: Loadwright.configuration)
          tracker.start!

          begin
            Execution::CollectorMiddleware.mount!(
              tracker: tracker,
              guard: Safety::EnvironmentGuard.new(config: Loadwright.configuration),
              secret: secret,
              # APP-SIDE, and it has to be. Under :http the process_action event fires
              # in THIS process, so db_runtime and view_runtime are observable only
              # here -- the harness never sees them. Without it, view time is
              # unavailable in :http mode and the report cannot tell a serialisation
              # problem from a database one.
              time_breakdown: Analysis::TimeBreakdown.new(config: Loadwright.configuration)
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

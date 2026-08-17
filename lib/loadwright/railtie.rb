# frozen_string_literal: true

require "rails/railtie"

module Loadwright
  # Rails integration point.
  #
  # This railtie deliberately does almost nothing on load. Two things must never
  # happen here:
  #
  #   1. Installing the collector middleware unconditionally. execution-modes.md
  #      requires it be mounted only while a guard-approved run is active, and
  #      unmounted afterwards — it exposes SQL, stack traces and timing.
  #
  #   2. Touching the database or reading configuration at boot. The initializer
  #      in the host app is evaluated in every environment, including production
  #      (which is why the generated file carries the `if defined?(Loadwright)`
  #      guard), so boot-time work here would run where the gem must be inert.
  #
  # The identity endpoint (production-safety.md Layer 1b) is the one exception
  # to (1): it is unguarded by design, exposes only the environment name and gem
  # version, and its presence in a production process is itself the signal the
  # remote-target check is looking for. It is still not mounted here in M0.
  #
  # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
  class Railtie < ::Rails::Railtie
    generators do
      require "generators/loadwright/install_generator"
    end
  end
end

# frozen_string_literal: true

require_relative "lib/loadwright/version"

Gem::Specification.new do |spec|
  spec.name    = "loadwright"
  spec.version = Loadwright::VERSION
  spec.authors = ["The Poorman"]
  spec.email   = ["matthew.w.rampey@gmail.com"]

  spec.summary = "Local load-testing diagnostic for Rails APIs: finds N+1s, " \
                 "missing indexes, memory bloat and pool pressure before code ships."
  spec.description = <<~DESC
    Loadwright discovers a Rails API's endpoints from an OpenAPI document and/or
    the app's own integration specs, seeds realistic data through the app's
    FactoryBot factories at increasing scale, exercises every endpoint under a
    scale x concurrency matrix, and reports where it falls over and why.

    It is a local developer diagnostic tool. It refuses to run outside
    development and test by default, never truncates tables, never terminates
    database sessions, and contains mail/job/outbound-HTTP side effects.
  DESC

  spec.homepage = "https://github.com/thepoorman/loadwright"
  spec.license  = "MIT"

  # ActiveSupport::IsolatedExecutionState (Rails 7.0+) is what makes per-request
  # metric correlation correct under concurrency; it honours the host app's
  # configured isolation_level instead of hand-rolling fiber/thread locals.
  # Supporting 6.1 would mean reimplementing that incorrectly in the highest
  # stakes code path, so 7.0 is a hard floor.
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  # AGENTS.md ships: the README points agents at it, and it is the
  # operational reference they act on. CLAUDE.md deliberately does not — it is
  # internal guidance for developing this gem, not for using it.
  spec.files = Dir[
    "lib/**/*.rb",
    "lib/**/*.tt",
    "README.md",
    "AGENTS.md",
    "LICENSE.txt"
  ]
  spec.require_paths = ["lib"]
  spec.executables   = ["loadwright"]
  spec.bindir        = "exe"

  # ---------------------------------------------------------------------------
  # Runtime dependencies — deliberately few.
  #
  # Loadwright runs inside a host Rails app's dev/test bundle. Anything the host
  # already provides (rails, activerecord, factory_bot, rspec) is NOT a runtime
  # dependency: taking one would let this gem dictate the host's versions, and
  # for factory_bot in particular we deliberately use the *host's* factories.
  # ---------------------------------------------------------------------------

  # Rails integration surface: railtie, generator, ActiveSupport::Notifications,
  # and IsolatedExecutionState. Floor only, never an upper pin.
  spec.add_dependency "activesupport", ">= 7.0"
  spec.add_dependency "railties", ">= 7.0"

  # :in_process execution drives ActionDispatch::Integration::Session directly.
  # railties already pulls actionpack in, but the dependency is direct and load
  # order matters (action_dispatch/testing/integration needs action_controller
  # loaded first), so it is declared rather than assumed.
  spec.add_dependency "actionpack", ">= 7.0"

  # OpenAPI discovery. discovery-and-load-engine.md is explicit that we must not
  # hand-roll YAML/JSON schema walking.
  #
  # PINNED CONSERVATIVELY, and deliberately tighter than the usual floor-only rule
  # applied above. Loadwright uses this gem for VALIDATION and then reads schemas out
  # of the RAW parsed hash, because Node::Schema#to_h is shallow and injects
  # additionalProperties: false — validating a real response against that would reject
  # any payload carrying a field the document did not enumerate. That is the right call
  # (see SchemaRef), but it means the code also depends on two things that are not
  # public API: Validation::Error responding to #context, and the raw hash shape.
  # A minor bump could change either silently, so the constraint stops at 0.10.x and
  # spec/loadwright/discovery/openapi_parser_contract_spec.rb fails loudly if the
  # assumptions stop holding.
  spec.add_dependency "openapi3_parser", ">= 0.10", "< 0.11"

  # Response validity gate. json_schemer supports JSON Schema 2020-12, which is
  # the dialect OpenAPI 3.1 uses; json-schema centres on draft-04/06/07.
  spec.add_dependency "json_schemer", "~> 2.5"

  # NOTE (deliberately absent):
  #   webmock  — used for block_outbound_http, but containment degrades with a
  #              loud warning when it is missing, so it stays a dev dependency.
  #              See production-safety.md, side-effect containment.
  #   puma     — only needed by :http execution mode, which uses whatever server
  #              the host app already runs. Dev dependency for our own e2e tests.
  #   pg/mysql2 — adapter-specific probes degrade gracefully by design.
end

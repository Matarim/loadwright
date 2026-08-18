# frozen_string_literal: true

require "loadwright/version"
require "loadwright/errors"

# Core value objects. These are real, not stubs: the three-state outcome model
# and capability gating are cross-cutting concerns that leak everywhere if they
# are retrofitted, so they exist before anything that would consume them.
require "loadwright/measurement"
require "loadwright/capability_profile"
require "loadwright/capability_timeline"
require "loadwright/coverage"
require "loadwright/endpoint_outcome"
require "loadwright/configuration"

# Subsystems. Stubs at this stage — see CLAUDE.md section 4 for build order.
require "loadwright/lifecycle"

require "loadwright/safety/environment_guard"
require "loadwright/safety/remote_target_identifier"
require "loadwright/safety/confirmation"

require "loadwright/side_effects/containment"

require "loadwright/instrumentation/current_request"
require "loadwright/instrumentation/query_tracker"

require "loadwright/execution/request"
require "loadwright/execution/raw_response"
require "loadwright/execution/request_metrics"
require "loadwright/execution/transport/base"
require "loadwright/execution/transport/in_process"
require "loadwright/execution/transport/http"
require "loadwright/execution/transport/null"
require "loadwright/execution/collector_middleware"
require "loadwright/execution/collector/base"
require "loadwright/execution/collector/direct"
require "loadwright/execution/collector/middleware"
require "loadwright/execution/collector/external"
require "loadwright/execution/identity_endpoint"
require "loadwright/execution/server_manager"
require "loadwright/execution/execution_context"

require "loadwright/discovery/endpoint"
require "loadwright/discovery/schema_ref"
require "loadwright/discovery/route_recognizer"
require "loadwright/discovery/openapi_source"
require "loadwright/discovery/integration_spec_source"
require "loadwright/discovery/route_source"
require "loadwright/discovery/merger"
require "loadwright/discovery/path_param_resolver"

require "loadwright/seeding/factory_bot_seeder"
require "loadwright/seeding/identity_pool"

require "loadwright/instrumentation/query_tracker"
require "loadwright/instrumentation/memory_tracker"
require "loadwright/instrumentation/connection_pool_tracker"
require "loadwright/instrumentation/pg_stat_tracker"

require "loadwright/engine/load_runner"
require "loadwright/engine/circuit_breaker"
require "loadwright/engine/resource_guard"
require "loadwright/engine/health_poller"

require "loadwright/analysis/response_validator"
require "loadwright/analysis/response_correlator"
require "loadwright/analysis/serializer_attribution"
require "loadwright/analysis/time_breakdown"
require "loadwright/analysis/explain_analyzer"
require "loadwright/analysis/pool_sizing_check"
require "loadwright/analysis/statistics"

require "loadwright/history/run_store"
require "loadwright/history/comparator"
require "loadwright/history/redactor"

require "loadwright/reporting/run_result"
require "loadwright/reporting/html_report"
require "loadwright/reporting/markdown_report"
require "loadwright/reporting/json_report"
require "loadwright/reporting/comparison_report"

# Loadwright — a local load-testing diagnostic for Rails APIs.
#
# Read CLAUDE.md first. The one rule that overrides all others: Loadwright must
# never generate load against production unless every layer of the safety gate
# in references/production-safety.md has been cleared. When a design choice is
# ambiguous, fail closed.
module Loadwright
  class << self
    def configuration
      @configuration ||= Configuration.new
    end
    alias config configuration

    def configure
      yield(configuration) if block_given?
      configuration
    end

    # Exists for the gem's own suite and for host apps that reconfigure between
    # runs. Not part of the documented user-facing surface.
    def reset_configuration!
      @configuration = nil
    end
  end
end

require "loadwright/railtie" if defined?(::Rails::Railtie)

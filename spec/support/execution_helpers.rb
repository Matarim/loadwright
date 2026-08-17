# frozen_string_literal: true

require "active_support/notifications"
require "active_support/isolated_execution_state"

# Test infrastructure for the execution layer.
#
# The scripted collector here is the counterpart to the Null transport: together
# they make the whole downstream pipeline — analysis, correlation, the engine's
# matrix construction, the guard's ladder — testable without booting Rails or
# opening a socket.
#
# Its convenience is also its hazard, which is why execution-modes.md requires at
# least one REAL end-to-end run per transport against examples/sample_app. Fast
# doubles drift from reality precisely because they are convenient.
module ExecutionHelpers
  # Returns whatever metrics it was handed, so a spec can state the exact metric
  # shape a downstream assertion depends on.
  class ScriptedCollector < Loadwright::Execution::Collector::Base
    attr_reader :begun, :collected

    def initialize(config: Loadwright.configuration, name: :direct, metrics: nil, degrade_after: nil)
      super(config: config)
      @name = name
      @metrics = metrics
      @degrade_after = degrade_after
      @begun = []
      @collected = []
    end

    def collector_name = @name

    def begin_request(request) = @begun << request.request_id

    def collect(request, raw_response, capability_epoch: 0)
      @collected << request.request_id

      if @degrade_after && @collected.length > @degrade_after
        degrade!(%i[n_plus_one_slope queries_per_returned_record], "scripted mid-run collection failure")
      end

      metrics = @metrics.respond_to?(:call) ? @metrics.call(request, raw_response) : @metrics
      return metrics if metrics.is_a?(Loadwright::Execution::RequestMetrics)

      Loadwright::Execution::RequestMetrics.new(
        request_id: request.request_id,
        collector: collector_name,
        capability_epoch: capability_epoch,
        queries: (metrics || {}).fetch(:queries, []),
        **default_measurements(metrics || {})
      )
    end

    private

    def default_measurements(overrides)
      base = {
        query_count: Loadwright::Measurement.value(overrides.fetch(:query_count, 1)),
        distinct_query_count: Loadwright::Measurement.value(overrides.fetch(:distinct_query_count, 1))
      }
      overrides.each do |key, value|
        next unless Loadwright::Execution::RequestMetrics::MEASURED_FIELDS.include?(key)

        base[key] = value.is_a?(Loadwright::Measurement) ? value : Loadwright::Measurement.value(value)
      end
      base
    end
  end

  def build_request(verb: :get, path: "/api/v1/posts", **rest)
    Loadwright::Execution::Request.new(verb: verb, path: path, **rest)
  end

  # Emits a real sql.active_record notification. The tracker's routing is what is
  # under test, not ActiveRecord — and a spec that needed a database to check
  # "does the subscriber attribute to the right bucket" would be slow enough that
  # the concurrency cases would not get written.
  def emit_sql(sql, name: "Post Load", duration: 0.5)
    ActiveSupport::Notifications.instrument("sql.active_record", sql: sql, name: name) do
      # A non-zero duration so timing assertions have something to read.
      sleep(duration / 1000.0) if duration.positive?
    end
  end

  # Boots a real Puma server in a thread on an ephemeral port and yields its base
  # URL. Used for the HTTP transport and correlation specs: a real socket, real
  # concurrent threads, no Rails.
  def with_local_http_app(app)
    require "puma"
    require "puma/configuration"

    server = Puma::Server.new(app)
    listener = server.add_tcp_listener("127.0.0.1", 0)
    port = listener.addr[1]
    server.run

    yield "http://127.0.0.1:#{port}"
  ensure
    server&.stop(true)
  end
end

RSpec.configure { |c| c.include ExecutionHelpers }

# frozen_string_literal: true

require "English"
require "net/http"
require "socket"
require "uri"
require "loadwright/errors"
require "loadwright/execution/identity_endpoint"

module Loadwright
  module Execution
    # Boots the app under test for :http mode, polls until it is healthy, and tears
    # it down.
    #
    # Teardown is registered with Lifecycle rather than trapped here. That is the
    # whole reason this class does not call Signal.trap: two subsystems trapping
    # the same signal races cleanup against itself, and an orphaned Puma process
    # holding a port is the most annoying thing a load-test tool can leave behind.
    # The seeder registers with the same registry, and the CLI installs the one
    # trap.
    class ServerManager
      DEFAULT_HOST = "127.0.0.1"

      attr_reader :port, :host, :pid, :base_url

      def initialize(config: Loadwright.configuration, lifecycle: nil, stdout: $stdout,
                     host: DEFAULT_HOST, collector_secret: nil)
        @config = config
        @lifecycle = lifecycle
        @stdout = stdout
        @host = host
        @collector_secret = collector_secret
        @pid = nil
        @port = nil
        @teardown_hook = nil
      end

      # True when Loadwright is pointing at a server it did not start. Capability
      # is unaffected by this — that is the collector's business — but provenance
      # is not: a report must name whether the target was booted here.
      def external_target? = !@config.http_target_url.to_s.strip.empty?

      def start!
        if external_target?
          @base_url = @config.http_target_url
          wait_for_health!
          return self
        end

        @port = allocate_port
        @base_url = "http://#{@host}:#{@port}"
        spawn_server
        register_teardown
        wait_for_health!
        self
      end

      def stop!
        return self if @pid.nil?

        pid = @pid
        @pid = nil

        # TERM, then wait, then KILL. Never anything cleverer: the point is that
        # the port is free and no process is left running, and escalating politely
        # is the only reliable way to get there.
        terminate(pid, "TERM")
        return self if reaped?(pid, timeout: 5)

        @stdout.puts "loadwright: server #{pid} did not exit on SIGTERM; sending SIGKILL"
        terminate(pid, "KILL")
        reaped?(pid, timeout: 2)
        self
      ensure
        @lifecycle&.unregister(@teardown_hook) if @teardown_hook
        @teardown_hook = nil
      end

      # Deliberately NOT Process.kill(0, pid): that returns true for a zombie — a
       # child that has exited but not been reaped — which is exactly the state a
      # server that dies during boot is in. The health loop would then wait out
      # the full http_boot_timeout and report a timeout instead of naming the real
      # cause, which is usually a missing database or a port already in use.
      def running?
        return false if @pid.nil?
        return false if @exit_status

        reaped = Process.waitpid(@pid, Process::WNOHANG)
        @exit_status = $CHILD_STATUS || true if reaped
        reaped.nil?
      rescue Errno::ECHILD, Errno::ESRCH
        @exit_status ||= true
        false
      end

      def exit_status = @exit_status

      # Used by the resource guard's Tier 2 poll. An unresponsive server under
      # :http is a Rung 5 global abort, not something to keep issuing requests
      # into — a failure mode :in_process cannot produce.
      def alive?
        return false unless external_target? || running?

        probe!
        true
      rescue StandardError
        false
      end

      def to_h
        {
          base_url: @base_url,
          booted_by_loadwright: !external_target?,
          pid: @pid,
          port: @port,
          collector_armed: !@collector_secret.nil?
        }
      end

      private

      def spawn_server
        command = @config.http_server_command || default_command
        env = { "PORT" => @port.to_s, "RAILS_ENV" => current_environment, "RACK_ENV" => current_environment }

        # The child arms its own collector middleware from this (see railtie.rb). Passed
        # in the environment because the harness cannot reach into another process to
        # mount it, and without it the run is transported but not instrumented.
        env["LOADWRIGHT_COLLECTOR_SECRET"] = @collector_secret if @collector_secret

        @stdout.puts "loadwright: booting #{command} on #{@base_url}"
        @pid = Process.spawn(env, command, out: :out, err: :err, pgroup: true)
      rescue StandardError => e
        raise ServerError, "could not boot the app under test with #{command.inspect}: #{e.class}: #{e.message}"
      end

      def default_command = "bundle exec puma -p #{@port} -e #{current_environment} --threads 1:5"

      def current_environment
        return ::Rails.env.to_s if defined?(::Rails) && ::Rails.respond_to?(:env) && ::Rails.env

        ENV["RAILS_ENV"] || ENV["RACK_ENV"] || "development"
      end

      # Bind to port 0, ask what we got, release it. Racy in principle; in practice
      # the alternative — a fixed port — collides with the app the developer
      # already has running on 3000, which is not a principle, it is Tuesday.
      def allocate_port
        server = TCPServer.new(@host, 0)
        server.addr[1]
      ensure
        server&.close
      end

      def wait_for_health!
        deadline = monotonic + @config.http_boot_timeout

        loop do
          if @pid && !running?
            raise ServerError,
                  "the app under test exited before becoming healthy (status: #{@exit_status.inspect}). Its " \
                  "output is above; the usual causes are a missing database, a failed migration, or a port " \
                  "already in use."
          end

          begin
            probe!
            @stdout.puts "loadwright: server healthy at #{@base_url}"
            return true
          rescue StandardError => e
            @last_health_error = e
          end

          if monotonic > deadline
            raise ServerError,
                  "the app under test at #{@base_url} did not become healthy within " \
                  "#{@config.http_boot_timeout}s (last error: #{@last_health_error&.class}: " \
                  "#{@last_health_error&.message})"
          end

          sleep 0.1
        end
      end

      # The identity endpoint is the health probe. It is mounted whenever the gem
      # is loaded, needs no secret, touches no database, and answering it proves
      # both that the process is up AND that it loads Loadwright — which is exactly
      # the pair of facts a boot check needs.
      def probe!
        uri = URI.join(@base_url, IdentityEndpoint::PATH)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                       open_timeout: 1, read_timeout: 2) do |http|
          http.request(Net::HTTP::Get.new(uri))
        end

        raise ServerError, "health probe returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        response
      end

      def register_teardown
        @teardown_hook = @lifecycle&.register("app server (pid #{@pid})", critical: true) { stop! }
      end

      def terminate(pid, signal)
        # Negative pid signals the process group, so a `bundle exec` wrapper does
        # not leave the real server orphaned behind it.
        Process.kill(signal, -pid)
      rescue Errno::ESRCH, Errno::EPERM
        begin
          Process.kill(signal, pid)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end
      end

      def reaped?(pid, timeout:)
        deadline = monotonic + timeout

        while monotonic < deadline
          return true if Process.waitpid(pid, Process::WNOHANG)

          sleep 0.05
        end
        false
      rescue Errno::ECHILD
        true
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end

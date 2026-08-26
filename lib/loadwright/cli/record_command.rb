# frozen_string_literal: true

require "loadwright/cli/app_loader"
require "loadwright/discovery/integration_spec_source"

module Loadwright
  class CLI
    # `loadwright record --specs spec/requests`.
    #
    # Runs the application's own request specs with a recorder prepended to
    # ActionDispatch::Integration::Session, capturing every request they make, and
    # writes them where discovery will find them.
    #
    # RECORDING, NOT PARSING. The alternative -- walking spec files with an AST
    # parser -- silently misses every request built through a helper, a shared
    # example, or a loop, and the misses are invisible because a partial result looks
    # exactly like a complete one. Executing the specs and watching what they actually
    # send has no such failure mode: whatever the suite exercises is what gets
    # recorded.
    #
    # It is a SEPARATE COMMAND from `run` for the same reason: running someone's test
    # suite is a big, slow, side-effecting thing to do, and it should never happen as
    # an implicit consequence of asking for a load test.
    class RecordCommand
      OK = 0
      FAILED = 1
      REFUSED = 3

      def initialize(options:, stdout: $stdout, stderr: $stderr, loader: nil, runner: nil)
        @options = options
        @stdout = stdout
        @stderr = stderr
        @loader = loader
        @runner = runner
      end

      def call
        paths = spec_paths
        return missing_specs if paths.empty?

        (@loader || AppLoader.new(stdout: @stdout)).load!
        warn_about_pending_migrations!

        source = Discovery::IntegrationSpecSource.new(config: config, stdout: @stdout)
        status = record_with(source, paths)
        report(source, status)
      rescue Loadwright::Error => e
        # The same breadth as RunCommand: every designed refusal prints its message
        # rather than a backtrace. A non-Loadwright error is left to surface, because
        # that is a bug in the gem and a backtrace is the right output for one.
        @stderr.puts "loadwright: #{e.message}"
        REFUSED
      end

      private

      def config = @config ||= Loadwright.configuration

      # `record` runs the host's specs, so it inherits their prerequisites. A stale
      # test schema fails every spec file with the same stack trace, and the signal is
      # buried under however many files that is. One line, before any of it.
      def warn_about_pending_migrations!
        return unless defined?(::ActiveRecord::Base)

        pending = ::ActiveRecord::Base.connection_pool.migration_context.needs_migration?
        return unless pending

        @stdout.puts "loadwright: this database has pending migrations, and your specs will " \
                     "almost certainly fail on them. Run `bin/rails db:migrate db:test:prepare` first."
      rescue StandardError
        # Best effort: not being able to ask is not a reason to refuse to record.
        nil
      end

      # --specs wins over the configured paths, because someone passing the flag is
      # narrowing this invocation on purpose.
      def spec_paths
        return Array(@options[:specs]) if @options[:specs]

        Array(config.integration_spec_paths).compact.map(&:to_s)
      end

      def record_with(source, paths)
        status = nil
        source.record!(output_path: source.default_output_path) do
          @stdout.puts "loadwright: recording requests from #{paths.join(', ')}"
          status = run_specs(paths)
        end
        status
      end

      # A SUBPROCESS WOULD RECORD NOTHING. The recorder is a module prepended to a
      # class inside THIS process, so the specs have to run here -- shelling out to
      # `rspec` would produce a green suite and an empty recording, which is the worst
      # of both outcomes because it looks like it worked.
      def run_specs(paths)
        return @runner.call(paths) if @runner

        require "rspec/core"
        # `RSpec.world.reset`, never `RSpec.reset`. The latter replaces the
        # Configuration singleton, discarding every setting a gem registered at
        # REQUIRE time -- and by now those gems are already in $LOADED_FEATURES, so
        # the `require` in spec_helper is a no-op and they never re-register.
        #
        # rswag is the common casualty: `c.add_setting :openapi_root` is gone, and the
        # host's own spec_helper dies with NoMethodError before a single example runs.
        # Any gem that extends RSpec configuration on load has the same problem.
        RSpec.world.reset
        RSpec::Core::Runner.run(paths.dup, @stderr, @stdout)
      end

      # A FAILING SUITE STILL RECORDS. The recorder captures the request before the
      # example's expectation runs, so a spec that failed on an assertion has still
      # told us the endpoint exists and what a valid request to it looks like -- which
      # is all discovery wanted from it. The failure is reported, not treated as a
      # reason to throw the recording away.
      def report(source, status)
        count = source.captured_count
        path = source.default_output_path

        if count.zero?
          @stderr.puts(status.to_i.zero? ? nothing_recorded_message(path) : suite_failed_message(status))
          return FAILED
        end

        @stdout.puts "loadwright: recorded #{count} request(s) to #{path}"
        @stdout.puts "  the spec run exited #{status}; the recording above is still usable" unless status.to_i.zero?
        @stdout.puts "  now run: bundle exec loadwright run --dry-run"
        OK
      end

      def missing_specs
        @stderr.puts <<~MSG.strip
          loadwright: nothing to record from.
          Pass a spec directory, or set integration_spec_paths in config/initializers/loadwright.rb:

              bundle exec loadwright record --specs spec/requests
        MSG
        REFUSED
      end

      # A suite that ERRORED and a suite that ran fine without making requests are
      # different problems, and the second message sends someone looking at the wrong
      # one entirely -- "your specs aren't integration specs" when actually
      # spec_helper never loaded.
      def suite_failed_message(status)
        <<~MSG.strip
          loadwright: the spec run failed (exit #{status}) before recording anything, so this is
          your suite's error rather than a discovery problem. Its output is above.

          If it passes under `rspec` and fails here, tell us: `record` runs your specs in a
          process that has already booted your app, and that difference is the usual cause.
        MSG
      end

      def nothing_recorded_message(path)
        <<~MSG.strip
          loadwright: the specs ran but made no recordable requests, so nothing was written to #{path}.
          Only ActionDispatch::Integration requests are recorded -- the `get`/`post` helpers in request
          and integration specs. Controller specs and unit specs make no HTTP request to capture.
        MSG
      end
    end
  end
end

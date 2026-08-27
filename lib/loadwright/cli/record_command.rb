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

      def initialize(options:, stdout: $stdout, stderr: $stderr, stdin: $stdin, loader: nil, runner: nil)
        @options = options
        @stdout = stdout
        @stderr = stderr
        @stdin = stdin
        @loader = loader
        @runner = runner
      end

      def call
        paths = spec_paths
        return missing_specs if paths.empty?

        (@loader || AppLoader.new(stdout: @stdout)).load!
        warn_about_recording_database!
        return REFUSED unless confirm_database_writes!

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

      # WHICH DATABASE YOUR SUITE IS ABOUT TO WRITE TO.
      #
      # `record` boots config/environment.rb and then runs RSpec IN THIS PROCESS. It
      # has to: the recorder is a module prepended to a class here, and a subprocess
      # would produce a green suite and an empty recording. But the consequence went
      # unsaid, and it is a real one. Because the app is already loaded, the
      # `ENV["RAILS_ENV"] ||= "test"` in a conventional rails_helper is a no-op -- so
      # the host's entire test suite executes against whatever database the CLI booted
      # into, which is normally development.
      #
      # A fully transactional suite rolls everything back and nothing leaks. That is
      # luck rather than containment: an example using truncation, a `before(:all)`, an
      # explicit commit, or a spec that deliberately tests transactional behaviour
      # writes to development data and stays there. A suite that truncates between
      # examples would empty the developer's development database.
      #
      # Loadwright's containment covers mail, jobs and outbound HTTP. It cannot cover
      # this, because this is the host's own code doing exactly what it was written to
      # do, in an environment it was never written for.
      #
      # SO: SAY SO, BEFORE THE SPECS RUN. Not a refusal -- running these specs is what
      # the user asked for, and the honest reading of the safety model is that this is
      # their suite and their call. But it is their call only if they know they are
      # making it, and the one thing a tool with this safety record must not do is this
      # silently.
      def warn_about_recording_database!
        current = current_database
        return if current.nil?

        @stdout.puts "loadwright: your specs are about to run IN THIS PROCESS, against the " \
                     "#{current} database (RAILS_ENV=#{rails_env})."

        declared = declared_test_database
        if declared && declared != current
          @stdout.puts "  Your test database is #{declared}. `record` boots the app first, so a " \
                       "conditional RAILS_ENV assignment in rails_helper does nothing and your suite " \
                       "will NOT reach it."
        end

        @stdout.puts "  A fully transactional suite rolls back and leaves nothing behind. One that " \
                     "truncates, commits, or uses before(:all) will write to this database -- and a " \
                     "suite that truncates between examples will empty it. Ctrl-C now if that is not " \
                     "what you want."
      end

      # THE ONE CASE WORTH MORE THAN A WARNING. The host declares a test database and
      # believes its suite runs there; it will not. That is detectable, not
      # hypothetical, and the costs of being wrong are wildly asymmetric -- a
      # transactional suite that proceeds loses nothing, a truncating one loses a
      # developer's database irreversibly, and "Ctrl-C now" only helps somebody
      # watching the scrollback in the second before their suite starts.
      #
      # So: an acknowledgement, not a refusal. The decision is the user's; it was the
      # invisibility that was wrong. Where there is no distinct test database to miss,
      # nothing is asked at all.
      def confirm_database_writes!
        return true unless config.confirm_recording_database
        return true if @options[:accept_database_writes]

        declared = declared_test_database
        return true if declared.nil? || declared == current_database

        unless @stdin.respond_to?(:tty?) && @stdin.tty?
          @stderr.puts "loadwright: refusing to run your specs against #{current_database} without an " \
                       "acknowledgement, because #{declared} is declared as your test database and will " \
                       "not be reached. Standard input is not a terminal, so pass " \
                       "--accept-database-writes (or set confirm_recording_database = false) if that is " \
                       "what you intend."
          return false
        end

        @stdout.print "Run your specs against #{current_database}? [y/N] "
        @stdout.flush
        return true if @stdin.gets.to_s.strip.casecmp("y").zero?

        @stderr.puts "loadwright: not recording."
        false
      end

      def current_database
        return nil unless defined?(::ActiveRecord::Base)

        name = ::ActiveRecord::Base.connection_db_config.database.to_s
        name.empty? ? nil : name
      rescue StandardError
        nil
      end

      # What the host's own database.yml calls its test database, where it says.
      # Absent rather than guessed: a nil here costs one line of the warning.
      def declared_test_database
        return nil unless defined?(::ActiveRecord::Base)

        config = ::ActiveRecord::Base.configurations.configs_for(env_name: "test").first
        name = config&.database.to_s
        name.empty? ? nil : name
      rescue StandardError
        nil
      end

      def rails_env
        defined?(::Rails) && ::Rails.respond_to?(:env) ? ::Rails.env.to_s : (ENV["RAILS_ENV"] || "unknown")
      rescue StandardError
        "unknown"
      end

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

      # NAMES WHAT IS STILL THERE. The message used to assert that nothing was written
      # to the path while the file at that path had just been replaced by an empty one,
      # so a reader had no reason to check. write! now refuses the write; this says
      # which of the two things happened.
      def nothing_recorded_message(path)
        existing = File.file?(path) ? "\n#{path} was left as it was, so an earlier recording is still usable." : ""

        <<~MSG.strip
          loadwright: the specs ran but made no recordable requests, so nothing was written to #{path}.
          Only ActionDispatch::Integration requests are recorded -- the `get`/`post` helpers in request
          and integration specs. Controller specs and unit specs make no HTTP request to capture.#{existing}
        MSG
      end
    end
  end
end

# frozen_string_literal: true

module Loadwright
  class CLI
    # Boots the host Rails application so a run has something to discover, seed and
    # exercise.
    #
    # `bundle exec loadwright run` is a standalone binary, not a Rails command, so
    # nothing has loaded the host app by the time the CLI gets control. Everything
    # downstream depends on the app being up: discovery reads the route set, seeding
    # reads FactoryBot definitions the app registered, and the :in_process transport
    # dispatches straight into `Rails.application`. Booting is therefore the first
    # thing `run` does, before the safety guard -- the guard's own environment
    # detection reads `Rails.env`, which does not exist until the app is loaded.
    #
    # Loading `config/environment.rb` is also what evaluates
    # `config/initializers/loadwright.rb`, so the user's `Loadwright.configure` block
    # takes effect here and nowhere earlier. A CLI flag that overrides config must be
    # applied AFTER this returns, or the initializer overwrites it.
    class AppLoader
      ENVIRONMENT_PATH = "config/environment.rb"

      def initialize(root: Dir.pwd, stdout: $stdout)
        @root = root
        @stdout = stdout
      end

      # Returns true if the app was booted here, false if it was already loaded
      # (the specs boot examples/sample_app once for the whole suite, and a second
      # `require` of an already-loaded environment is a no-op that still costs the
      # confusion of looking like a fresh boot).
      def load!
        return false if already_loaded?

        path = File.join(@root, ENVIRONMENT_PATH)
        raise ConfigurationError, not_a_rails_app_message unless File.exist?(path)

        @stdout.puts "loadwright: booting the application (#{ENVIRONMENT_PATH})"
        require path
        verify_booted!
        true
      rescue LoadError, StandardError => e
        raise if e.is_a?(Loadwright::Error)

        raise ConfigurationError, boot_failed_message(e)
      end

      def already_loaded?
        defined?(::Rails) && ::Rails.respond_to?(:application) && !::Rails.application.nil?
      end

      private

      # A require that succeeds without leaving Rails.application set means the file
      # was not what we thought it was. Failing here is much cheaper than failing
      # four subsystems later with an error that names none of this.
      def verify_booted!
        return if already_loaded?

        raise ConfigurationError,
              "#{ENVIRONMENT_PATH} loaded but Rails.application is not set, so this is not a Rails " \
              "application Loadwright can drive. Run loadwright from the root of the Rails app you " \
              "want to test."
      end

      def not_a_rails_app_message
        <<~MSG.strip
          refusing to run: no #{ENVIRONMENT_PATH} under #{@root}.
          Loadwright drives a Rails application, and it looks for one in the current working
          directory. Run it from your application's root:

              cd /path/to/your/app && bundle exec loadwright run --dry-run
        MSG
      end

      # The app's own boot failure, surfaced as the app's boot failure. Swallowing it
      # into "could not start" would send the user looking for a bug in Loadwright.
      def boot_failed_message(error)
        <<~MSG.strip
          refusing to run: the application raised while booting, so there is nothing to test yet.
          This is your app's boot error, not a Loadwright one -- reproduce it with
          `bundle exec rails runner 1` and fix it there first.

            #{Loadwright.brief(error)}
        MSG
      end
    end
  end
end

# frozen_string_literal: true

require "fileutils"

module Loadwright
  class CLI
    # `loadwright init` — writes config/initializers/loadwright.rb.
    #
    # The same file `rails generate loadwright:install --minimal` produces, without
    # needing the Rails generator to be reachable. Defaults to the short form: every
    # key it omits keeps its default, so a later release that improves one reaches
    # the user instead of being frozen at whatever the day's value was.
    class InitCommand
      OK = 0
      REFUSED = 3

      TEMPLATES = {
        minimal: "loadwright.minimal.rb.tt",
        full: "loadwright.rb.tt"
      }.freeze

      DESTINATION = "config/initializers/loadwright.rb"

      def initialize(options:, stdout: $stdout, stderr: $stderr, root: Dir.pwd)
        @options = options
        @stdout = stdout
        @stderr = stderr
        @root = root
      end

      def call
        destination = File.join(@root, DESTINATION)
        return already_exists(destination) if File.exist?(destination) && !@options[:force]

        FileUtils.mkdir_p(File.dirname(destination))
        File.write(destination, render)

        @stdout.puts "      create  #{DESTINATION}"
        next_steps
        OK
      rescue SystemCallError => e
        @stderr.puts "loadwright: could not write #{DESTINATION}: #{e.class}: #{e.message}"
        REFUSED
      end

      private

      # The templates carry no ERB tags in the minimal form; the full one is written
      # by the generator, which has the detection results this command does not.
      def render
        File.read(template_path)
      end

      def template_path
        key = @options[:full] ? :full : :minimal
        File.expand_path("../../generators/loadwright/templates/#{TEMPLATES.fetch(key)}", __dir__)
      end

      def already_exists(destination)
        @stderr.puts <<~MSG.strip
          loadwright: #{DESTINATION} already exists, and overwriting it would discard your settings.
          Pass --force to replace it, or delete it first.
        MSG
        REFUSED
      end

      def next_steps
        @stdout.puts "        next  set auth_token_provider or auth_login unless the API is public"
        @stdout.puts "        next  narrow included_paths before the first run on a large app"
        @stdout.puts "        next  `bundle exec loadwright run --dry-run` sends zero requests"
      end
    end
  end
end

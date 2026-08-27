# frozen_string_literal: true

require "rails/generators/base"

module Loadwright
  module Generators
    # `rails generate loadwright:install`
    #
    # Writes config/initializers/loadwright.rb from the template, adds
    # Loadwright's output directories to the host app's .gitignore, and pre-fills
    # the discovery section from what it can actually find on disk.
    #
    # The template is the authority for the gem's config surface — a spec asserts
    # every key in it exists on Loadwright::Configuration and vice versa, so the
    # two cannot drift.
    class InstallGenerator < ::Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Creates config/initializers/loadwright.rb with Loadwright's full configuration surface."

      # Conventional locations, most-likely first. Checked rather than guessed:
      # a generated initializer pointing at a file that does not exist produces a
      # first run that fails at discovery, which is the single most discouraging
      # place for a new user to fail.
      OPENAPI_CANDIDATES = [
        "swagger/v1/swagger.yaml",
        "swagger/v1/swagger.json",
        "swagger/swagger.yaml",
        "openapi.yaml",
        "openapi.yml",
        "openapi.json",
        "doc/openapi.yaml",
        "public/openapi.yaml",
        "public/api-docs/v1/swagger.yaml"
      ].freeze

      INTEGRATION_SPEC_CANDIDATES = %w[
        spec/requests
        spec/integration
        spec/api
        test/integration
      ].freeze

      # Reports and persisted run records are drawn from a real database. They
      # contain SQL, request/response shapes, and — depending on redaction
      # settings — bodies. They do not belong in version control.
      # (reporting.md and run-comparison.md both require this.)
      GITIGNORE_ENTRIES = ["/tmp/loadwright/"].freeze

      class_option :minimal, type: :boolean, default: false,
                             desc: "Write only the settings most apps need, leaving the rest at their defaults"

      def create_initializer
        source = options[:minimal] ? "loadwright.minimal.rb.tt" : "loadwright.rb.tt"
        template source, "config/initializers/loadwright.rb"
      end

      def add_output_dirs_to_gitignore
        path = ".gitignore"
        entries = GITIGNORE_ENTRIES.reject { |entry| gitignore_contains?(path, entry) }

        return say_status(:identical, ".gitignore already ignores tmp/loadwright", :blue) if entries.empty?

        # A Rails app always has one, but append_to_file silently skips a missing
        # file — and silently not ignoring a directory full of database-derived
        # output is not an acceptable outcome.
        create_file(path, "") unless File.file?(destination_path(path))

        append_to_file path, <<~IGNORE

          # Loadwright reports and persisted run records. These are generated from a
          # real database and may contain SQL and request/response data.
          #{entries.join("\n")}
        IGNORE
      end

      def report_discovery_detection
        if detected_openapi_paths.any?
          say_status :found, "OpenAPI document: #{detected_openapi_paths.join(', ')}", :green
        else
          say_status :none, "no OpenAPI document found; set openapi_spec_paths if you have one", :yellow
        end

        if detected_integration_spec_paths.any?
          say_status :found, "request specs: #{detected_integration_spec_paths.join(', ')}", :green
        else
          say_status :none, "no request-spec directory found; set integration_spec_paths if you have one", :yellow
        end
      end

      def report_next_steps
        say_status :next, "review config/initializers/loadwright.rb before running anything", :green
        say_status :next, "set auth_token_provider unless the API is fully public", :green
        say_status :next, "`bundle exec loadwright run --dry-run` sends zero requests", :green
      end

      private

      # Consumed by the template. Public-ish by convention in Rails generators:
      # ERB is evaluated in the generator's binding, so a private method is still
      # reachable from the template.
      def detected_openapi_paths
        @detected_openapi_paths ||= OPENAPI_CANDIDATES.select { |candidate| File.file?(destination_path(candidate)) }
      end

      def detected_integration_spec_paths
        @detected_integration_spec_paths ||=
          INTEGRATION_SPEC_CANDIDATES.select { |candidate| File.directory?(destination_path(candidate)) }
      end

      def destination_path(relative) = File.expand_path(relative, destination_root)

      def gitignore_contains?(path, entry)
        full = destination_path(path)
        return false unless File.file?(full)

        # Compare on the trimmed entry so "tmp/loadwright/" and "/tmp/loadwright/"
        # are not both appended across repeated installs.
        needle = entry.delete_prefix("/").chomp("/")
        File.read(full).each_line.any? { |line| line.strip.delete_prefix("/").chomp("/") == needle }
      end
    end
  end
end

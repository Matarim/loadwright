# frozen_string_literal: true

# Boots examples/sample_app once per suite run, for the specs that need a live
# database and real query patterns.
#
# Loaded LAZILY, not at spec_helper time: booting Rails and ActiveRecord costs
# ~0.5s, and the majority of the suite runs against the Null transport and does not
# need it. Tag an example group `:sample_app` to get it.
module SampleAppHelpers
  APP_ROOT = File.expand_path("../../examples/sample_app", __dir__)

  class << self
    def boot!
      return if @booted

      # A dedicated database file, so running the suite never touches whatever state
      # someone left in the development one.
      ENV["RAILS_ENV"] = "test"
      ENV["SAMPLE_APP_DATABASE"] ||= File.join(APP_ROOT, "db", "loadwright-suite.sqlite3")

      require File.join(APP_ROOT, "config", "environment")
      require "factory_bot"

      FactoryBot.definition_file_paths = [File.join(APP_ROOT, "spec")]
      # FactoryBot::Registry is Enumerable but has no #empty?, and re-running
      # find_definitions raises DuplicateDefinitionError.
      FactoryBot.find_definitions if FactoryBot.factories.count.zero?

      @booted = true
    end

    def booted? = @booted == true
  end

  def sample_app = SampleApp::Application

  # Loadwright itself never truncates anything. This is the SUITE resetting its own
  # fixture to a known state, which is a different thing entirely — and the seeder
  # spec asserts that Loadwright's own cleanup issues no TRUNCATE.
  def reset_sample_app!
    SampleApp::Database.reset!
  end

  def sample_app_factory_map
    { "post" => { factory: :post, trait: :with_comments } }
  end

  # Counts application queries for a block, using the same exclusions QueryTracker
  # applies, so a spec's own expectation and the gem's counting agree.
  def count_app_queries
    count = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
      payload = ActiveSupport::Notifications::Event.new(*args).payload
      next if Loadwright::Instrumentation::QueryTracker::IGNORED_NAMES.include?(payload[:name])
      next if payload[:sql].to_s.match?(Loadwright::Instrumentation::QueryTracker::IGNORED_SQL)

      count += 1
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end

RSpec.configure do |config|
  config.include SampleAppHelpers, :sample_app
  config.before(:context, :sample_app) { SampleAppHelpers.boot! }
  config.before(:each, :sample_app) { SampleApp::Database.reset! }
end

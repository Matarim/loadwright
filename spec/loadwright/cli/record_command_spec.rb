# frozen_string_literal: true

require "loadwright/cli/record_command"
require "tmpdir"

RSpec.describe Loadwright::CLI::RecordCommand do
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }
  let(:loader) { instance_double(Loadwright::CLI::AppLoader, load!: false) }

  def command(options = {}, runner: nil)
    described_class.new(options: { specs: "spec/requests" }.merge(options),
                        stdout: stdout, stderr: stderr, loader: loader, runner: runner)
  end

  # THE rswag BLOCKER. `RSpec.reset` replaces the Configuration singleton, discarding
  # every setting a gem registered at REQUIRE time. Those gems are already in
  # $LOADED_FEATURES by the time `record` runs -- Loadwright boots the app first, which
  # requires them -- so the `require` in spec_helper is a no-op and they never
  # re-register. rswag's `c.add_setting :openapi_root` disappears, and the host's own
  # spec_helper dies with NoMethodError before a single example runs.
  #
  # A spec file that passes under `rspec` and dies under `loadwright record` is the
  # worst kind of bug: it looks like the user's fault.
  #
  # These drive the REAL path -- no injected runner -- because the injected one
  # returns before any of this happens, which would make the examples vacuous.
  describe "running the host's specs" do
    around do |example|
      # Restored, because the suite running this IS an RSpec configuration.
      RSpec.configuration.add_setting :loadwright_probe_setting
      example.run
    end

    it "keeps settings other gems registered at require time" do
      observed = nil
      allow(RSpec::Core::Runner).to receive(:run) do
        observed = RSpec.configuration.respond_to?(:loadwright_probe_setting=)
        0
      end

      command.send(:run_specs, ["spec/requests"])

      expect(observed).to be(true)
    end

    it "still clears example groups, which is what the reset was for" do
      allow(RSpec::Core::Runner).to receive(:run).and_return(0)
      expect(RSpec.world).to receive(:reset)

      command.send(:run_specs, ["spec/requests"])
    end
  end

  # "the specs ran but made no recordable requests" told a user their specs were not
  # integration specs, when in fact spec_helper had never loaded. That message sends
  # someone to rewrite tests that were fine.
  describe "when the suite errors before recording anything" do
    it "says it was the suite that failed, not the recording" do
      command(runner: ->(_paths) { 1 }).call

      expect(stderr.string).to include("your suite's error rather than a discovery problem")
      expect(stderr.string).not_to include("Only ActionDispatch::Integration requests")
    end

    it "still says the other thing when the suite passed and simply made no requests" do
      command(runner: ->(_paths) { 0 }).call

      expect(stderr.string).to include("Only ActionDispatch::Integration requests")
    end
  end
  # `record` boots the app and then runs RSpec IN THIS PROCESS -- it has to, because
  # the recorder is a module prepended to a class here. The consequence went unsaid:
  # the `ENV["RAILS_ENV"] ||= "test"` in a conventional rails_helper is a no-op by
  # then, so the host's whole test suite runs against the database the CLI booted
  # into. A transactional suite rolls back and nothing leaks; a truncating one would
  # empty a developer's development database.
  #
  # Not a refusal -- running these specs is what was asked for. But it is the user's
  # call only if they know they are making it.
  describe "which database the specs are about to write to" do
    def with_databases(current:, test: nil)
      db_config = double("db_config", database: current)
      test_config = test && double("test_config", database: test)
      configurations = double("configurations", configs_for: [test_config].compact)
      stub_const("ActiveRecord", Module.new)
      migrations = double("migration_context", needs_migration?: false)
      stub_const("ActiveRecord::Base",
                 double("Base", connection_db_config: db_config, configurations: configurations,
                                connection_pool: double("pool", migration_context: migrations)))
      yield
    end

    it "names the database before a single example runs" do
      with_databases(current: "widgets_development") do
        command({}, runner: ->(_paths) { 0 }).call
      end

      expect(stdout.string).to include("IN THIS PROCESS").and include("widgets_development")
    end

    it "says what a non-transactional suite would do to it" do
      with_databases(current: "widgets_development") do
        command({}, runner: ->(_paths) { 0 }).call
      end

      expect(stdout.string).to include("truncates between examples will empty it")
    end

    # The specific trap: the host DOES declare a test database, and believes its suite
    # uses it.
    it "says the declared test database will not be reached" do
      with_databases(current: "widgets_development", test: "widgets_test") do
        command({}, runner: ->(_paths) { 0 }).call
      end

      expect(stdout.string).to include("widgets_test").and include("will NOT reach it")
    end

    it "says nothing extra when the suite is already on the test database" do
      with_databases(current: "widgets_test", test: "widgets_test") do
        command({}, runner: ->(_paths) { 0 }).call
      end

      expect(stdout.string).not_to include("will NOT reach it")
    end

    # Not being able to ask is not a reason to refuse to record.
    it "records anyway when there is no database to ask about" do
      hide_const("ActiveRecord")

      expect { command({}, runner: ->(_paths) { 0 }).call }.not_to raise_error
    end
  end
end

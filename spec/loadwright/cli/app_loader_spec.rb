# frozen_string_literal: true

require "loadwright/cli/app_loader"
require "tmpdir"
require "fileutils"

RSpec.describe Loadwright::CLI::AppLoader do
  let(:stdout) { StringIO.new }

  def loader(root) = described_class.new(root: root, stdout: stdout)

  # STATED, NOT ASSUMED. Every example below whose premise is "no Rails application
  # is loaded" needs that premise to be true, and in this suite it is not: anything
  # tagged :sample_app boots a real Rails app into the suite's own process and leaves
  # it there. Without hide_const these three examples PASSED VACUOUSLY whenever a
  # :sample_app example had already run -- `already_loaded?` returned true, load!
  # short-circuited, and "expected an error, got none" never happened because the
  # order happened to be favourable.
  #
  # This is the exact failure mode CLAUDE.md's `rake spec:seeds` rule exists for, and
  # it was reproduced here before being fixed: running this file after a :sample_app
  # example turned three green examples red.
  shared_context "with no Rails application loaded" do
    before { hide_const("::Rails") }
  end

  describe "when there is no Rails app here" do
    include_context "with no Rails application loaded"

    it "refuses, and says the working directory is the problem" do
      Dir.mktmpdir("not-an-app-") do |dir|
        expect { loader(dir).load! }
          .to raise_error(Loadwright::ConfigurationError, %r{no config/environment\.rb})
      end
    end

    # The message has to name the fix. "Run it from the app root" is the actual cause
    # almost every time this fires, and someone who reads only the first line should
    # still know what to do.
    it "names the fix rather than only the symptom" do
      Dir.mktmpdir("not-an-app-") do |dir|
        loader(dir).load!
      rescue Loadwright::ConfigurationError => e
        expect(e.message).to include("cd /path/to/your/app")
      end
    end
  end

  describe "when the app itself raises while booting" do
    include_context "with no Rails application loaded"

    # THE POINT OF THIS ONE: the user must be sent to their own app, not to
    # Loadwright. A boot failure reported as "Loadwright could not start" sends
    # someone hunting for a bug in the wrong codebase entirely.
    it "attributes the failure to the app and quotes the original error" do
      Dir.mktmpdir("broken-app-") do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "environment.rb"), "raise ArgumentError, 'bad initializer'")

        expect { loader(dir).load! }
          .to raise_error(Loadwright::ConfigurationError, /your app's boot error.*ArgumentError: bad initializer/m)
      end
    end
  end

  describe "when a Rails app is already loaded" do
    it "does not boot a second time" do
      Dir.mktmpdir("app-") do |dir|
        subject = loader(dir)
        # No environment.rb exists here, so a load attempt would raise. Returning
        # false proves it short-circuited on the already-loaded check instead.
        allow(subject).to receive(:already_loaded?).and_return(true)

        expect(subject.load!).to be(false)
        expect(stdout.string).to be_empty
      end
    end
  end

  # A file that loads without leaving Rails.application set is not a Rails app, and
  # saying so here is much cheaper than failing four subsystems later with an error
  # that names none of this.
  describe "when environment.rb loads but sets no application" do
    include_context "with no Rails application loaded"

    it "refuses rather than continuing into discovery" do
      Dir.mktmpdir("hollow-app-") do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "environment.rb"), "# loads fine, boots nothing")

        expect { loader(dir).load! }
          .to raise_error(Loadwright::ConfigurationError, /Rails\.application is not set/)
      end
    end
  end
end

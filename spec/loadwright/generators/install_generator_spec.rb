# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "rails/generators"
require "generators/loadwright/install_generator"

# Runs the real generator against a real (empty) directory tree. Asserting on the
# generated FILE rather than on the template is the point: the `if defined?`
# guard has to survive ERB rendering, and a spec that only reads the template
# would not notice if rendering dropped it.
RSpec.describe Loadwright::Generators::InstallGenerator do
  around do |example|
    Dir.mktmpdir("loadwright-generator") do |dir|
      @app_root = dir
      example.run
    end
  end

  # Thor writes status lines to $stdout, which would make the suite output
  # unreadable. Captured rather than muted because Thor's shell API for muting
  # differs between versions and the status lines are not what is under test.
  def run_generator!
    original = $stdout
    $stdout = @generator_output = StringIO.new
    described_class.start([], destination_root: @app_root, behavior: :invoke, verbose: false)
  ensure
    $stdout = original
  end

  def generator_output = @generator_output.string

  def app_file(relative) = File.join(@app_root, relative)
  def initializer = File.read(app_file("config/initializers/loadwright.rb"))

  describe "the generated initializer" do
    before { run_generator! }

    # INV-04. Rails evaluates initializers in every environment; the gem is in
    # the :development, :test group. Without this, booting production raises
    # NameError and the app does not start.
    it "wraps everything in the `if defined?(Loadwright)` guard" do
      expect(initializer).to match(/^if defined\?\(Loadwright\)$/)
      expect(initializer.lines.last.strip).to eq("end")
    end

    it "explains why the guard is required, so nobody removes it as noise" do
      expect(initializer).to match(/guard below is REQUIRED/i)
    end

    it "is valid Ruby" do
      expect { RubyVM::InstructionSequence.compile(initializer) }.not_to raise_error
    end

    # The generated file, not the template, is what a user reads. If ERB
    # rendering dropped a section, this catches it.
    it "documents every configuration key" do
      assigned = initializer.scan(/^\s*#?\s*config\.([a-z0-9_]+)\s*=/).flatten.map(&:to_sym).uniq

      expect(Loadwright::Configuration.keys - assigned).to be_empty
    end

    it "loads cleanly against the real Configuration, so no key is a phantom" do
      # Evaluated with a stub Rails so Rails.root.join in the template resolves.
      # This is the strongest available check that the file actually works: it
      # runs the generated code through the real DSL.
      stub_const("Rails", Module.new do
        def self.root = Pathname.new("/tmp/loadwright-fake-app")
      end)

      expect { eval(initializer, TOPLEVEL_BINDING, "loadwright.rb") }.not_to raise_error # rubocop:disable Security/Eval
      expect(Loadwright.configuration.execution_mode).to eq(:in_process)
    end
  end

  describe ".gitignore" do
    # Reports and run records are generated from a real database and may contain
    # SQL and request/response data. reporting.md and run-comparison.md both
    # require the generator handles this rather than trusting the user to.
    it "adds Loadwright's output directory" do
      File.write(app_file(".gitignore"), "/log/*\n")

      run_generator!

      expect(File.read(app_file(".gitignore"))).to include("/tmp/loadwright/")
    end

    it "explains what is being ignored and why" do
      File.write(app_file(".gitignore"), "")

      run_generator!

      expect(File.read(app_file(".gitignore"))).to match(/may contain SQL and request\/response data/)
    end

    it "does not duplicate the entry when run twice" do
      File.write(app_file(".gitignore"), "")

      run_generator!
      run_generator!

      expect(File.read(app_file(".gitignore")).scan("/tmp/loadwright/").length).to eq(1)
    end

    it "recognises an equivalent entry the user wrote by hand" do
      File.write(app_file(".gitignore"), "tmp/loadwright\n")

      run_generator!

      expect(File.read(app_file(".gitignore")).scan(%r{tmp/loadwright}).length).to eq(1)
    end
  end

  describe "discovery detection" do
    # An initializer pointing at a file that does not exist produces a first run
    # that fails at discovery — the most discouraging place for a new user to
    # fail. So the generator checks rather than guesses.
    it "pre-fills openapi_spec_paths from a document it found" do
      FileUtils.mkdir_p(app_file("swagger/v1"))
      File.write(app_file("swagger/v1/swagger.yaml"), "openapi: 3.0.0\n")

      run_generator!

      expect(initializer).to include('config.openapi_spec_paths = [')
      expect(initializer).to include('Rails.root.join("swagger/v1/swagger.yaml")')
      expect(initializer).to include("Detected on disk when this file was generated")
    end

    it "finds a non-conventional location too" do
      File.write(app_file("openapi.yaml"), "openapi: 3.0.0\n")

      run_generator!

      expect(initializer).to include('Rails.root.join("openapi.yaml")')
    end

    it "says plainly that it found nothing rather than pointing at a missing file silently" do
      run_generator!

      expect(initializer).to include("No OpenAPI/Swagger document was found")
      # The convention path is still offered, so the key is documented.
      expect(initializer).to include('Rails.root.join("swagger/v1/swagger.yaml")')
    end

    it "pre-fills integration_spec_paths from directories that exist" do
      FileUtils.mkdir_p(app_file("spec/requests"))

      run_generator!

      expect(initializer).to include('Rails.root.join("spec/requests")')
      expect(initializer).not_to include('Rails.root.join("spec/integration")')
    end

    it "lists every request-spec directory it found" do
      FileUtils.mkdir_p(app_file("spec/requests"))
      FileUtils.mkdir_p(app_file("spec/api"))

      run_generator!

      expect(initializer).to include('Rails.root.join("spec/requests")')
      expect(initializer).to include('Rails.root.join("spec/api")')
    end
  end
end

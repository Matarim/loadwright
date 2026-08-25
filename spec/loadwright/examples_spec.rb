# frozen_string_literal: true

# The shipped examples, checked against the real configuration surface.
#
# WHY THESE ARE TESTED AT ALL. An example initializer is the thing people COPY. A
# config key renamed in lib/ leaves every example still parsing, still looking
# authoritative, and silently setting nothing — `config.some_renamed_key = true`
# raises no error, produces no warning, and has no effect.
#
# That is the same phantom-key failure the documentation-drift spec exists for,
# except an example is worse: it is copied wholesale into a real app by someone who
# has no reason to doubt it, and the setting they believed they enabled is simply
# absent. Someone who copies `mutating_endpoints/` and loses a containment key finds
# out when the run mails their customers.
require "pathname"

# NAMESPACED, not bare. A constant assigned inside an `RSpec.describe` block lands on
# Object, because Ruby resolves the assignment lexically and the lexical scope is the
# file's top level -- so two spec files declaring the same name silently overwrite each
# other, and the winner depends on load order. That is not hypothetical: an earlier
# version of this file declared ASSIGNMENT, documentation_drift_spec declares a
# DIFFERENT one, and the drift spec started passing or failing by seed.
module ExampleFixtures
  ROOT = File.join(SpecPaths::ROOT, "examples")

  # From references/readme-and-examples.md. Listed here rather than globbed so that
  # deleting one is a test failure rather than a silent reduction in coverage.
  EXPECTED = %w[
    minimal openapi_driven integration_spec_driven factory_heavy paginated_api
    http_mode shared_dev_database mysql large_monolith mutating_endpoints sample_app
  ].freeze

  # sample_app is a Rails application, not a config example; it carries its own
  # config/ instead of a drop-in initializer.
  WITH_INITIALIZER = (EXPECTED - %w[sample_app]).freeze

  CONFIG_ASSIGNMENT = /^\s*config\.([a-z_0-9]+)\s*=/
end

RSpec.describe "shipped examples" do

  def initializer_path(name) = File.join(ExampleFixtures::ROOT, name, "loadwright.rb")

  def keys_in(name)
    File.read(initializer_path(name)).scan(ExampleFixtures::CONFIG_ASSIGNMENT).flatten.map(&:to_sym).uniq
  end

  it "ships every example the reference doc lists" do
    present = Dir.children(ExampleFixtures::ROOT).select { |entry| File.directory?(File.join(ExampleFixtures::ROOT, entry)) }

    expect(present.sort).to eq(ExampleFixtures::EXPECTED.sort)
  end

  ExampleFixtures::WITH_INITIALIZER.each do |name|
    describe name do
      it "has an initializer and a README" do
        expect(File).to exist(initializer_path(name))
        expect(File).to exist(File.join(ExampleFixtures::ROOT, name, "README.md"))
      end

      # THE GUARD. Every key an example sets must exist on Configuration.
      it "sets only keys that exist" do
        unknown = keys_in(name) - Loadwright::Configuration.keys

        expect(unknown).to be_empty,
                           "#{name}/loadwright.rb sets #{unknown.join(', ')}, which no longer exist on " \
                           "Loadwright::Configuration. Someone copying this example would silently get " \
                           "nothing."
      end

      # Rails evaluates every initializer in every environment, and this gem lives in
      # the :development, :test group. Without the guard, booting production raises
      # NameError and the app does not start — and these are the files people copy.
      it "wraps everything in the `if defined?(Loadwright)` guard" do
        expect(File.read(initializer_path(name))).to match(/^if defined\?\(Loadwright\)$/)
      end

      it "is valid Ruby" do
        expect { RubyVM::InstructionSequence.compile(File.read(initializer_path(name))) }
          .not_to raise_error
      end

      # An example that assigns a value Configuration rejects is worse than no
      # example: it fails at run start, in someone else's app, after they trusted it.
      #
      # The WHOLE FILE is evaluated, guard included, with Loadwright.configure
      # redirected at a throwaway config -- so this exercises what a host app
      # actually does rather than a hand-extracted approximation of it.
      #
      # Rails is stubbed rather than relied upon: several examples reference
      # Rails.root, and whether Rails is loaded here depends on whether the sample
      # app booted first. Stubbing makes the premise explicit and order-independent.
      it "produces a configuration that validates" do
        config = Loadwright::Configuration.new
        stub_const("Rails", double(root: Pathname.new("/tmp/example-app")))
        allow(Loadwright).to receive(:configure).and_yield(config)

        expect { eval(File.read(initializer_path(name)), binding, initializer_path(name)) } # rubocop:disable Security/Eval
          .not_to raise_error
        expect { config.validate! }.not_to raise_error
      end

      it "actually assigns something, rather than being an empty shell" do
        expect(keys_in(name)).not_to be_empty
      end

      it "explains who it is for rather than only what it sets" do
        readme = File.read(File.join(ExampleFixtures::ROOT, name, "README.md"))

        expect(readme).not_to include("Placeholder — not written yet")
        expect(readme.length).to be > 400
      end
    end
  end
end

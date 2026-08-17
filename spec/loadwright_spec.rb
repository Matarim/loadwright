# frozen_string_literal: true

RSpec.describe Loadwright do
  it "has a version" do
    expect(Loadwright::VERSION).to match(/\A\d+\.\d+\.\d+/)
  end

  # Checked in a subprocess rather than in-process. The generator specs must
  # `require "rails/generators"`, so once any of them has loaded, `Rails` is
  # defined here — and an in-process assertion on `defined?(Rails)` would pass or
  # fail depending on spec ordering, which makes it worse than no assertion.
  it "loads with no Rails at all" do
    script = 'require "loadwright"; ' \
             'raise "Rails leaked in" if defined?(Rails); ' \
             'raise "config broken" unless Loadwright.config.is_a?(Loadwright::Configuration)'

    expect(system(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script))
      .to be(true)
  end

  # The in-process half: Rails may be loaded without an application being
  # initialised, which is the state the gem's own suite runs in.
  it "resolves every configuration default with no Rails application initialised" do
    expect(defined?(Rails) && Rails.respond_to?(:application) && Rails.application).to be_falsey

    config = Loadwright::Configuration.new

    expect { config.to_h }.not_to raise_error
    expect(config.confirmation_phrase).to be_nil
    expect(config.openapi_spec_paths).to eq([])
  end

  describe "the public surface at this stage" do
    it "exposes the core value objects" do
      expect(Loadwright::Measurement).to be_a(Class)
      expect(Loadwright::CapabilityProfile).to be_a(Class)
      expect(Loadwright::CapabilityTimeline).to be_a(Class)
      expect(Loadwright::EndpointOutcome).to be_a(Class)
      expect(Loadwright::Configuration).to be_a(Class)
    end

    it "roots every error at Loadwright::Error" do
      [
        Loadwright::SafetyError,
        Loadwright::ConfigurationError,
        Loadwright::UnavailableMeasurementError
      ].each { |klass| expect(klass.ancestors).to include(Loadwright::Error) }
    end
  end
end

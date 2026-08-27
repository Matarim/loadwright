# frozen_string_literal: true

require "tmpdir"

# `record` runs the host's specs against TEST. `run` measures DEVELOPMENT. That is the
# documented two-command workflow, so recorded ids are routinely ids that do not exist
# in the database being measured -- every request 404s, and the endpoint is reported as
# broken when the tool simply asked for a record that was never there.
RSpec.describe Loadwright::Discovery::IntegrationSpecSource, "recording environment" do
  let(:config) { Loadwright::Configuration.new }
  let(:stdout) { StringIO.new }

  def write_recording(dir, environment:)
    path = File.join(dir, "recorded-requests.json")
    File.write(path, JSON.generate(
                       "version" => described_class::FORMAT_VERSION,
                       "environment" => environment,
                       "requests" => [{
                         "verb" => "get", "template" => "/api/v1/widgets/{widget_id}",
                         "path" => "/api/v1/widgets/wgt-aaaa1111", "path_values" => { "widget_id" => "wgt-aaaa1111" },
                         "status" => 200
                       }]
                     ))
    path
  end

  def endpoints_from(path) = described_class.new(config: config, stdout: stdout).endpoints(input_path: path)

  around { |example| Dir.mktmpdir("recording-env-") { |dir| @dir = dir; example.run } }

  # STATED, NOT ASSUMED. `current_environment` reads ::Rails.env when Rails is loaded
  # and falls back to ENV otherwise -- and whether Rails is loaded here depends on
  # whether a :sample_app example ran first. hide_const pins the ENV branch so this
  # file means the same thing under every seed.
  around do |example|
    previous = ENV.fetch("RAILS_ENV", nil)
    ENV["RAILS_ENV"] = "development"
    example.run
  ensure
    ENV["RAILS_ENV"] = previous
  end

  before { hide_const("Rails") }

  context "when the recording came from the environment being measured" do
    it "uses the recorded values" do
      endpoint = endpoints_from(write_recording(@dir, environment: "development")).first

      expect(endpoint.recorded_path_values[:widget_id]).to eq(["wgt-aaaa1111"])
    end
  end

  context "when the recording came from a different database" do
    let(:endpoint) { endpoints_from(write_recording(@dir, environment: "test")).first }

    it "drops the recorded values rather than requesting ids that do not exist here" do
      expect(endpoint.recorded_path_values[:widget_id]).to eq([])
    end

    # The parameter must stay DECLARED, or the template and the parameter list
    # disagree and the raw template goes out as a URL.
    it "keeps the parameter declared, so it resolves or is reported unresolvable" do
      expect(endpoint.path_params).to eq([:widget_id])
    end

    it "says so, naming both environments" do
      endpoint

      expect(stdout.string).to include("recorded in test").and include("targets development")
    end
  end

  # An older recording predates the field entirely; treat it as before.
  it "leaves a recording with no environment alone" do
    path = File.join(@dir, "old.json")
    File.write(path, JSON.generate("version" => described_class::FORMAT_VERSION,
                                   "requests" => [{ "verb" => "get", "template" => "/api/v1/widgets/{widget_id}",
                                                    "path" => "/api/v1/widgets/7",
                                                    "path_values" => { "widget_id" => "7" }, "status" => 200 }]))

    expect(endpoints_from(path).first.recorded_path_values[:widget_id]).to eq(["7"])
  end
end

# frozen_string_literal: true

require "tmpdir"

# `record` runs the host's specs against TEST. `run` measures DEVELOPMENT. That is the
# documented two-command workflow, so recorded ids are routinely ids that do not exist
# in the database being measured -- every request 404s, and the endpoint is reported as
# broken when the tool simply asked for a record that was never there.
RSpec.describe Loadwright::Discovery::IntegrationSpecSource, "recording environment" do
  let(:config) { Loadwright::Configuration.new }
  let(:stdout) { StringIO.new }

  def write_recording(dir, environment:, database: nil)
    path = File.join(dir, "recorded-requests.json")
    File.write(path, JSON.generate(
                       {
                         "version" => described_class::FORMAT_VERSION,
                         "environment" => environment,
                         "database" => database
                       }.compact.merge(
                         "requests" => [{
                           "verb" => "get", "template" => "/api/v1/widgets/{widget_id}",
                           "path" => "/api/v1/widgets/wgt-aaaa1111",
                           "path_values" => { "widget_id" => "wgt-aaaa1111" },
                           "status" => 200
                         }]
                       )
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

  # WHAT THE ENVIRONMENT NAME WAS STANDING IN FOR. `record` boots the app in one
  # environment and then runs specs that connect to another; Rails.env never moves,
  # so a recording made entirely of test ids was tagged "development" and compared
  # equal to a development run. The guard passed and dropped nothing, which is worse
  # than having no guard: it reports all clear.
  describe "the database the ids actually came from" do
    def with_database(name)
      db_config = instance_double("ActiveRecord::DatabaseConfig", database: name)
      base = class_double("ActiveRecord::Base", connection_db_config: db_config)
      stub_const("ActiveRecord", Module.new)
      stub_const("ActiveRecord::Base", base)
      yield
    end

    it "drops recorded values when the recording names a different database, whatever the environments say" do
      endpoint = with_database("widgets_development") do
        endpoints_from(write_recording(@dir, environment: "development", database: "widgets_test")).first
      end

      expect(endpoint.recorded_path_values[:widget_id]).to eq([])
      expect(stdout.string).to include("widgets_test").and include("widgets_development")
    end

    it "keeps recorded values when the databases match, whatever the environments say" do
      endpoint = with_database("widgets_development") do
        endpoints_from(write_recording(@dir, environment: "test", database: "widgets_development")).first
      end

      expect(endpoint.recorded_path_values[:widget_id]).to eq(["wgt-aaaa1111"])
    end

    # An absent answer must fall back to the environment name rather than invent a
    # mismatch: dropping good ids costs coverage for no reason.
    it "falls back to the environment name when the recording carries no database" do
      endpoint = with_database("widgets_development") do
        endpoints_from(write_recording(@dir, environment: "test")).first
      end

      expect(endpoint.recorded_path_values[:widget_id]).to eq([])
    end
  end

  describe "what a recording records about itself" do
    it "samples the environment and database when the request is captured, not when the file is written" do
      source = described_class.new(config: config, stdout: stdout)
      recognizer = instance_double(Loadwright::Discovery::RouteRecognizer)
      allow(recognizer).to receive(:recognize).and_return(
        Loadwright::Discovery::RouteRecognizer::Recognition.new(
          template: "/api/v1/widgets/{widget_id}", path_values: { widget_id: "wgt-aaaa1111" },
          controller: "widgets", action: "show"
        )
      )
      source.instance_variable_set(:@recognizer, recognizer)

      # The value observed while the request was being issued...
      allow(source).to receive(:data_source).and_return("environment" => "test", "database" => "widgets_test")
      source.send(:capture, verb: :get, path: "/api/v1/widgets/wgt-aaaa1111", session: fake_session)

      # ...survives a write! that happens back in the CLI process, where the answer
      # would have been "development".
      allow(source).to receive(:data_source).and_return("environment" => "development",
                                                        "database" => "widgets_development")
      path = File.join(@dir, "written.json")
      source.write!(path)

      expect(JSON.parse(File.read(path))).to include("environment" => "test", "database" => "widgets_test")
    end

    def fake_session
      request = instance_double("ActionDispatch::Request", GET: {}, POST: {}, headers: {})
      instance_double("ActionDispatch::Integration::Session", request: request, response: nil)
    end
  end
end

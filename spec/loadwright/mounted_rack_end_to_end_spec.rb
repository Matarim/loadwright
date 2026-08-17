# frozen_string_literal: true

require "tmpdir"

# A MOUNTED RACK APP, RECORDED AND RECOVERED, against a real Rails router.
#
# Rails reports `mount MountedApi => "/mounted"` as ONE route, so route recognition
# answers "/mounted" for every request inside it. Recording three endpoints produced
# three records with the same template; they merged into one, which was then requested
# at the bare mount point and 404'd.
#
# Grape, Sinatra and Roda all look like this to Rails, and rswag-documented Grape APIs
# are a common Rails-API shape.
RSpec.describe "recording behind a mounted Rack app", :sample_app do
  let(:stdout) { StringIO.new }
  let(:source) { Loadwright::Discovery::IntegrationSpecSource.new(config: config, stdout: stdout) }
  let(:config) { Loadwright::Configuration.new }

  # Drives the real router: a real Session against the real mounted app, so the
  # collapse being recovered from is the one Rails actually produces.
  def record_requests!(paths)
    Dir.mktmpdir("mounted-") do |dir|
      output = File.join(dir, "recorded.json")
      source.install!
      session = ActionDispatch::Integration::Session.new(sample_app)
      session.host = "localhost"
      paths.each { |path| session.get(path) }
      source.write!(output)
      JSON.parse(File.read(output))["requests"]
    ensure
      source.uninstall!
    end
  end

  let(:recorded) do
    record_requests!([
                       "/api/v1/mounted/widgets/wgt-aaaa1111-2222-3333-4444-555566667777",
                       "/api/v1/mounted/widgets/wgt-bbbb1111-2222-3333-4444-555566667777/customer"
                     ])
  end

  it "records the requests rather than losing them to an unrecognised route" do
    expect(recorded.length).to eq(2)
  end

  # Without recovery all of these are "/api/v1/mounted".
  it "recovers a distinct template per endpoint" do
    expect(recorded.map { |r| r["template"] }.uniq.length).to eq(2)
  end

  it "keeps the id, so the endpoint can be requested against a record that exists" do
    customer = recorded.find { |r| r["path"].end_with?("/customer") }

    expect(customer["template"]).to end_with("/widgets/{widget_id}/customer")
    expect(customer["path_values"]["widget_id"]).to eq("wgt-bbbb1111-2222-3333-4444-555566667777")
  end

  it "says it inferred them, rather than presenting a guess as router output" do
    recorded

    expect(stdout.string).to include("behind a mounted Rack app")
  end

  # The whole point: these become separate endpoints downstream.
  it "yields one endpoint per operation once merged" do
    Dir.mktmpdir("mounted-endpoints-") do |dir|
      output = File.join(dir, "recorded.json")
      File.write(output, JSON.generate("version" => 1, "requests" => recorded))

      endpoints = source.endpoints(input_path: output)

      expect(endpoints.length).to eq(2)
      expect(endpoints.map(&:to_s)).to all(include("{widget_id}"))
    end
  end
end

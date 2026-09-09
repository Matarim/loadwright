# frozen_string_literal: true

# THE ATTRIBUTION HAS TO WORK WHERE THE RESIDUAL IS, and the residual is largest on
# exactly the stacks that emit no `process_action` event. A mounted Rack app -- Grape,
# Sinatra, Roda -- has no controller, so the spans it announced were collected and then
# stranded behind a Breakdown that never existed. The endpoint block said nothing, with
# no warning and no unavailable-reason, and a reader concluded there was nothing inside
# `other` when nothing had been read.
#
# This is the end-to-end version of that: a real run, through a real mounted app, whose
# only account of its own time is an ActiveSupport::Notifications event.
RSpec.describe "`other` attribution on a mounted Rack app", :sample_app do
  let(:stdout) { StringIO.new }

  let(:config) do
    Loadwright::Configuration.new.tap do |c|
      c.scale_factors = [2]
      c.page_size_sweep = [2]
      c.concurrency_levels = [1]
      c.requests_per_endpoint_per_level = 2
      c.warmup_requests = 0
      c.attribute_other_time = true
    end
  end

  let(:endpoint) do
    Loadwright::Discovery::Endpoint.new(path: "/api/v1/mounted/widgets/7", verb: :get, source: :openapi)
  end

  def run!
    reset_sample_app!
    context = Loadwright::Execution::ExecutionContext.build_in_process(config: config, app: sample_app)
    context.start!
    result = Loadwright::Engine::LoadRunner.new(
      config: config, context: context, stdout: stdout
    ).run(endpoints: [endpoint])
    context.stop!
    result
  end

  it "names the span the mounted app announced, with no controller event anywhere" do
    result = run!

    attribution = result.time_breakdowns[endpoint.to_s][:other_attribution]
    expect(attribution[:top].map { |span| span[:name] }).to include("calculate_payoff.mounted_api")
  end

  it "reports the endpoint's view runtime as unavailable, which is how the stack is identified" do
    result = run!

    expect(result.time_breakdowns[endpoint.to_s][:view_ms]).to be_nil
  end
end

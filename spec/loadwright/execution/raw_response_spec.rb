# frozen_string_literal: true

RSpec.describe Loadwright::Execution::RawResponse do
  let(:request) { build_request }

  def response(**overrides)
    described_class.new(**{ request: request, status: 200, body: "[]" }.merge(overrides))
  end

  describe "header normalisation" do
    # Rack 3 gives lowercase keys; ActionDispatch and Net::HTTP do not. A lookup
    # that guessed wrong would read nil — and for a metrics header, nil means "no
    # queries measured" rather than "header not found", which is a wrong number
    # rather than a missing one.
    it "is case-insensitive regardless of which transport produced it" do
      subject = response(headers: { "Content-Type" => "application/json", "x-loadwright-query-count" => "9" })

      expect(subject.header("content-type")).to eq("application/json")
      expect(subject.header("X-Loadwright-Query-Count")).to eq("9")
    end

    it "joins multi-value headers rather than handing back an array" do
      expect(response(headers: { "set-cookie" => %w[a=1 b=2] }).header("set-cookie")).to eq("a=1, b=2")
    end

    it "tolerates no headers at all" do
      expect(response(headers: nil).header("content-type")).to be_nil
      expect(response(headers: nil).content_type).to eq("")
    end
  end

  describe "what it does and does not judge" do
    it "answers whether the status was a success" do
      expect(response(status: 200)).to be_success
      expect(response(status: 204)).to be_success
      expect(response(status: 403)).not_to be_success
      expect(response(status: 500)).not_to be_success
    end

    # An exception is not the same as a 5xx. A LockWaitTimeout is a contention
    # event routed to the resource guard; a 500 is an endpoint error the circuit
    # breaker counts. Collapsing them would make the two mechanisms fight.
    it "distinguishes an escaped exception from an error status" do
      errored = response(status: nil, error: StandardError.new("lock wait timeout"))

      expect(errored).to be_errored
      expect(errored).not_to be_success
      expect(response(status: 500)).not_to be_errored
    end

    it "reports the status family, for classification without magic numbers" do
      expect(response(status: 422).status_family).to eq(4)
      expect(response(status: nil).status_family).to be_nil
    end

    # The deliberate omission. "Did it 200?" and "did it do the work?" must not
    # collapse into one boolean — ResponseValidator owns the second question,
    # because it has the schema and the seeded-record context this object does
    # not.
    it "has no opinion on whether the response was valid" do
      expect(described_class.instance_methods).not_to include(:valid?, :healthy?, :outcome)
    end
  end

  describe "payload size" do
    it "measures bytes, not characters, since payload growth is a byte signal" do
      expect(response(body: "héllo").body_bytes).to eq(6)
    end

    it "is zero for no body at all" do
      expect(response(body: nil).body_bytes).to eq(0)
    end
  end

  it "carries the correlation id through from the request" do
    expect(response.request_id).to eq(request.request_id)
  end

  it "summarises itself without the body, so metadata cannot leak a payload" do
    audit = response(body: '{"secret":"hunter2"}').to_h

    expect(audit).to include(status: 200, body_bytes: 20)
    expect(audit.values.join).not_to include("hunter2")
  end
end

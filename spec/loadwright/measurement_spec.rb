# frozen_string_literal: true

RSpec.describe Loadwright::Measurement do
  describe "an available measurement" do
    subject(:measurement) { described_class.value(12) }

    it { is_expected.to be_available }
    it { is_expected.not_to be_unavailable }

    it "exposes the value" do
      expect(measurement.value).to eq(12)
    end

    it "has no reason" do
      expect(measurement.reason).to be_nil
    end

    it "renders as the value" do
      expect(measurement.to_s).to eq("12")
    end
  end

  describe "an unavailable measurement" do
    subject(:measurement) { described_class.unavailable("no collector middleware") }

    it { is_expected.to be_unavailable }
    it { is_expected.not_to be_available }

    # The central guarantee of this class: an unmeasured quantity cannot be
    # coaxed into producing a number that a report would render as "0".
    it "raises rather than returning a value" do
      expect { measurement.value }
        .to raise_error(Loadwright::UnavailableMeasurementError, /no collector middleware/)
    end

    it "carries the reason, which is what the report prints instead of a number" do
      expect(measurement.reason).to eq("no collector middleware")
      expect(measurement.to_s).to eq("unavailable (no collector middleware)")
    end

    it "yields the caller's default only when asked explicitly" do
      expect(measurement.value_or(0)).to eq(0)
    end

    it "refuses to be constructed without a reason" do
      expect { described_class.unavailable("") }.to raise_error(ArgumentError, /requires a reason/)
      expect { described_class.unavailable(nil) }.to raise_error(ArgumentError, /requires a reason/)
    end
  end

  describe "rejecting nil values" do
    # "measured, and it was nil" is not a meaningful state, and permitting it
    # reintroduces exactly the ambiguity this class removes.
    it "refuses a nil value" do
      expect { described_class.value(nil) }.to raise_error(ArgumentError, /not meaningful/)
    end
  end

  describe "#map" do
    it "transforms an available value" do
      expect(described_class.value(4).map { |v| v * 2 }).to eq(described_class.value(8))
    end

    it "propagates unavailability without invoking the block" do
      unavailable = described_class.unavailable("no middleware")
      expect { |b| unavailable.map(&b) }.not_to yield_control
      expect(unavailable.map { |v| v * 2 }).to eq(unavailable)
    end

    it "preserves the original reason through a chain of derivations" do
      result = described_class.unavailable("app process died").map { |v| v + 1 }.map { |v| v * 3 }
      expect(result.reason).to eq("app process died")
    end
  end

  describe "deliberate absence of numeric coercion" do
    # Arithmetic on a possibly-unmeasured quantity must be an explicit decision
    # at the call site. If these ever start responding, a nil-as-zero bug has a
    # route back in.
    it "does not respond to numeric coercion methods" do
      measurement = described_class.value(5)
      expect(measurement).not_to respond_to(:to_i)
      expect(measurement).not_to respond_to(:to_f)
      expect(measurement).not_to respond_to(:coerce)
      expect(measurement).not_to respond_to(:+)
    end
  end

  describe "value semantics" do
    it "compares by value and reason" do
      expect(described_class.value(1)).to eq(described_class.value(1))
      expect(described_class.value(1)).not_to eq(described_class.value(2))
      expect(described_class.unavailable("a")).to eq(described_class.unavailable("a"))
      expect(described_class.unavailable("a")).not_to eq(described_class.unavailable("b"))
      expect(described_class.value(1)).not_to eq(described_class.unavailable("a"))
    end

    it "is frozen" do
      expect(described_class.value(1)).to be_frozen
    end

    it "hashes equal values together" do
      set = [described_class.value(1), described_class.value(1)].uniq
      expect(set.length).to eq(1)
    end
  end
end

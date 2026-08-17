# frozen_string_literal: true

# STATUS: stub subsystem. These examples assert the class is defined and
# wired into the require graph — real behaviour specs land with the
# implementation, per CLAUDE.md section 4.
RSpec.describe Loadwright::Instrumentation::QueryTracker do
  describe "#start!" do
    it "is not implemented yet" do
      expect { described_class.new.start! }.to raise_error(NotImplementedError, /start!/)
    end
  end

  describe "#stop!" do
    it "is not implemented yet" do
      expect { described_class.new.stop! }.to raise_error(NotImplementedError, /stop!/)
    end
  end

  describe "#metrics" do
    it "is not implemented yet" do
      expect { described_class.new.metrics }.to raise_error(NotImplementedError, /metrics/)
    end
  end
end

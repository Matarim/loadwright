# frozen_string_literal: true

# STATUS: stub subsystem. These examples assert the class is defined and
# wired into the require graph — real behaviour specs land with the
# implementation, per CLAUDE.md section 4.
RSpec.describe Loadwright::Engine::HealthPoller do
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

  describe "#sample" do
    it "is not implemented yet" do
      expect { described_class.new.sample }.to raise_error(NotImplementedError, /sample/)
    end
  end
end

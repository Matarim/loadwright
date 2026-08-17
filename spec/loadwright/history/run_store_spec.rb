# frozen_string_literal: true

# STATUS: stub subsystem. These examples assert the class is defined and
# wired into the require graph — real behaviour specs land with the
# implementation, per CLAUDE.md section 4.
RSpec.describe Loadwright::History::RunStore do
  describe "#write!" do
    it "is not implemented yet" do
      expect { described_class.new.write! }.to raise_error(NotImplementedError, /write!/)
    end
  end

  describe "#list" do
    it "is not implemented yet" do
      expect { described_class.new.list }.to raise_error(NotImplementedError, /list/)
    end
  end

  describe "#prune!" do
    it "is not implemented yet" do
      expect { described_class.new.prune! }.to raise_error(NotImplementedError, /prune!/)
    end
  end
end

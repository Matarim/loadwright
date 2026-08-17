# frozen_string_literal: true

# STATUS: stub subsystem. These examples assert the class is defined and
# wired into the require graph — real behaviour specs land with the
# implementation, per CLAUDE.md section 4.
RSpec.describe Loadwright::Execution::ServerManager do
  describe "#boot!" do
    it "is not implemented yet" do
      expect { described_class.new.boot! }.to raise_error(NotImplementedError, /boot!/)
    end
  end

  describe "#teardown!" do
    it "is not implemented yet" do
      expect { described_class.new.teardown! }.to raise_error(NotImplementedError, /teardown!/)
    end
  end
end

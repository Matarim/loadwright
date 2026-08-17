# frozen_string_literal: true

# STATUS: stub subsystem. These examples assert the class is defined and
# wired into the require graph — real behaviour specs land with the
# implementation, per CLAUDE.md section 4.
RSpec.describe Loadwright::Execution::ExecutionContext do
  describe "#issue" do
    it "is not implemented yet" do
      expect { described_class.new.issue }.to raise_error(NotImplementedError, /issue/)
    end
  end

  describe "#degrade!" do
    it "is not implemented yet" do
      expect { described_class.new.degrade! }.to raise_error(NotImplementedError, /degrade!/)
    end
  end
end

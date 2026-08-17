# frozen_string_literal: true

# STATUS: stub subsystem. These examples assert the class is defined and
# wired into the require graph — real behaviour specs land with the
# implementation, per CLAUDE.md section 4.
RSpec.describe Loadwright::Analysis::PoolSizingCheck do
  describe "#check" do
    it "is not implemented yet" do
      expect { described_class.new.check }.to raise_error(NotImplementedError, /check/)
    end
  end
end

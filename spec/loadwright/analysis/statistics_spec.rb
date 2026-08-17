# frozen_string_literal: true

# STATUS: stub subsystem. These examples assert the class is defined and
# wired into the require graph — real behaviour specs land with the
# implementation, per CLAUDE.md section 4.
RSpec.describe Loadwright::Analysis::Statistics do
  describe "#percentiles" do
    it "is not implemented yet" do
      expect { described_class.new.percentiles }.to raise_error(NotImplementedError, /percentiles/)
    end
  end
end

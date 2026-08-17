# frozen_string_literal: true

# STATUS: stub subsystem. These examples assert the class is defined and
# wired into the require graph — real behaviour specs land with the
# implementation, per CLAUDE.md section 4.
RSpec.describe Loadwright::Analysis::ResponseCorrelator do
  describe "#correlate" do
    it "is not implemented yet" do
      expect { described_class.new.correlate }.to raise_error(NotImplementedError, /correlate/)
    end
  end
end

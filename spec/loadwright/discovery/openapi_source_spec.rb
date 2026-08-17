# frozen_string_literal: true

# STATUS: stub subsystem. These examples assert the class is defined and
# wired into the require graph — real behaviour specs land with the
# implementation, per CLAUDE.md section 4.
RSpec.describe Loadwright::Discovery::OpenapiSource do
  describe "#endpoints" do
    it "is not implemented yet" do
      expect { described_class.new.endpoints }.to raise_error(NotImplementedError, /endpoints/)
    end
  end
end

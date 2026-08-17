# frozen_string_literal: true

# STATUS: stub subsystem. These examples assert the class is defined and
# wired into the require graph — real behaviour specs land with the
# implementation, per CLAUDE.md section 4.
RSpec.describe Loadwright::Seeding::FactoryBotSeeder do
  describe "#seed!" do
    it "is not implemented yet" do
      expect { described_class.new.seed! }.to raise_error(NotImplementedError, /seed!/)
    end
  end

  describe "#cleanup!" do
    it "is not implemented yet" do
      expect { described_class.new.cleanup! }.to raise_error(NotImplementedError, /cleanup!/)
    end
  end
end

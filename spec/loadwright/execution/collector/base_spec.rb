# frozen_string_literal: true

# STATUS: stub subsystem. These examples assert the class is defined and
# wired into the require graph — real behaviour specs land with the
# implementation, per CLAUDE.md section 4.
RSpec.describe Loadwright::Execution::Collector::Base do
  describe "#collect" do
    it "is not implemented yet" do
      expect { described_class.new.collect }.to raise_error(NotImplementedError, /collect/)
    end
  end

  describe "#capabilities" do
    it "is not implemented yet" do
      expect { described_class.new.capabilities }.to raise_error(NotImplementedError, /capabilities/)
    end
  end
end

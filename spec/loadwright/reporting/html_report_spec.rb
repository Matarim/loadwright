# frozen_string_literal: true

# STATUS: stub subsystem. These examples assert the class is defined and
# wired into the require graph — real behaviour specs land with the
# implementation, per CLAUDE.md section 4.
RSpec.describe Loadwright::Reporting::HtmlReport do
  describe "#render" do
    it "is not implemented yet" do
      expect { described_class.new.render }.to raise_error(NotImplementedError, /render/)
    end
  end
end

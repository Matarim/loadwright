# frozen_string_literal: true

require "loadwright/cli/init_command"
require "tmpdir"

RSpec.describe Loadwright::CLI::InitCommand do
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  around { |example| Dir.mktmpdir("init-") { |dir| @dir = dir; example.run } }

  def command(options = {}) = described_class.new(options: options, stdout: stdout, stderr: stderr, root: @dir)

  def written = File.read(File.join(@dir, "config/initializers/loadwright.rb"))

  it "writes an initializer" do
    expect(command.call).to eq(described_class::OK)
    expect(written).to include("Loadwright.configure")
  end

  # Rails evaluates initializers in every environment and this gem is dev/test only.
  # Without the guard a production boot raises NameError.
  it "wraps it in the `if defined?` guard" do
    command.call

    expect(written).to match(/^if defined\?\(Loadwright\)$/)
  end

  it "produces valid Ruby" do
    command.call
    path = File.join(@dir, "config/initializers/loadwright.rb")

    expect(system("ruby", "-c", path, out: File::NULL, err: File::NULL)).to be(true)
  end

  it "names no key that does not exist" do
    command.call
    keys = written.scan(/^\s*#?\s*config\.([a-z0-9_]+)\s*=/).flatten.map(&:to_sym).uniq

    expect(keys - Loadwright::Configuration.keys).to be_empty
  end

  # THE POINT OF THE MINIMAL FORM. Assigning a key freezes it at today's value, so a
  # later release that widens a default never reaches the user -- which is exactly how
  # a broadened credential-redaction list failed to reach anyone who had generated an
  # initializer before it shipped.
  it "leaves most keys unassigned, so improved defaults still reach the user" do
    command.call
    assigned = written.scan(/^\s*config\.([a-z0-9_]+)\s*=/).flatten.uniq

    expect(assigned.length).to be < 10
    expect(assigned).not_to include("redact_header_patterns")
  end

  it "writes the full surface when asked" do
    command(full: true).call

    expect(written.lines.length).to be > 300
  end

  describe "when an initializer already exists" do
    before { command.call }

    it "refuses rather than discarding the user's settings" do
      second = described_class.new(options: {}, stdout: StringIO.new, stderr: stderr, root: @dir)

      expect(second.call).to eq(described_class::REFUSED)
      expect(stderr.string).to include("--force")
    end

    it "overwrites when forced" do
      expect(command(force: true).call).to eq(described_class::OK)
    end
  end

  it "tells the user what to do next" do
    command.call

    expect(stdout.string).to include("auth_token_provider").and include("--dry-run")
  end
end

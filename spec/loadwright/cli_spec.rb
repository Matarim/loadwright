# frozen_string_literal: true

require "loadwright/cli"
require "stringio"

RSpec.describe Loadwright::CLI do
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  def run(*argv)
    described_class.start(argv, stdout: stdout, stderr: stderr)
  end

  describe "--help" do
    it "lists the commands AGENTS.md tells agents to use" do
      run("--help")

      %w[run record runs baseline compare].each do |command|
        expect(stdout.string).to include(command)
      end
    end

    it "documents the safety flags" do
      run("--help")

      expect(stdout.string).to include("--dry-run")
      expect(stdout.string).to include("--execute")
      expect(stdout.string).to include("--i-understand-the-risk")
    end
  end

  describe "--version" do
    it "prints the version" do
      expect(run("--version")).to eq(0)
      expect(stdout.string).to include(Loadwright::VERSION)
    end
  end

  describe "with no command" do
    it "prints usage and exits non-zero" do
      expect(run).to eq(1)
      expect(stdout.string).to include("Usage: loadwright")
    end
  end

  describe "with an unknown command" do
    it "says so and exits non-zero" do
      expect(run("obliterate")).to eq(1)
      expect(stderr.string).to include("unknown command: obliterate")
    end
  end

  describe "commands" do
    it "are not implemented yet" do
      expect { run("run") }.to raise_error(NotImplementedError, /not implemented yet/)
    end
  end

  describe "flag parsing" do
    it "rejects an invalid execution mode" do
      expect { run("--mode", "carrier_pigeon", "run") }.to raise_error(OptionParser::InvalidArgument)
    end
  end
end

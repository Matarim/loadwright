# frozen_string_literal: true

RSpec.describe Loadwright::Safety::Confirmation do
  # StringIO#tty? is false, which is the correct default for a piped stdin. A
  # terminal is simulated by overriding just that one method, so the interactive
  # path is exercised without needing a pty.
  def terminal(input)
    StringIO.new(input).tap do |io|
      io.define_singleton_method(:tty?) { true }
    end
  end

  let(:stdout) { StringIO.new }

  describe "#obtain!" do
    it "accepts the exact phrase" do
      confirmation = described_class.new(stdin: terminal("AcmeApp\n"), stdout: stdout)

      expect(confirmation.obtain!("AcmeApp", prompt: "danger")).to be(true)
      expect(stdout.string).to include("danger")
      expect(stdout.string).to include("Type AcmeApp to continue")
    end

    it "rejects a near miss" do
      confirmation = described_class.new(stdin: terminal("acmeapp\n"), stdout: stdout)

      expect { confirmation.obtain!("AcmeApp", prompt: "danger") }
        .to raise_error(Loadwright::SafetyError, /did not match/)
    end

    it "rejects a bare yes, which is the whole reason the phrase is app-specific" do
      confirmation = described_class.new(stdin: terminal("yes\n"), stdout: stdout)

      expect { confirmation.obtain!("AcmeApp", prompt: "danger") }
        .to raise_error(Loadwright::SafetyError, /did not match/)
    end

    it "rejects an empty answer" do
      confirmation = described_class.new(stdin: terminal("\n"), stdout: stdout)

      expect { confirmation.obtain!("AcmeApp", prompt: "danger") }
        .to raise_error(Loadwright::SafetyError, /did not match/)
    end

    # Distinguished from a wrong answer because the cause and the fix differ:
    # end of input almost always means the prompt was piped.
    it "distinguishes end of input from a wrong answer" do
      confirmation = described_class.new(stdin: terminal(""), stdout: stdout)

      expect { confirmation.obtain!("AcmeApp", prompt: "danger") }
        .to raise_error(Loadwright::SafetyError, /end of input/)
    end

    # Layer 3 condition 2 is "an interactive confirmation prompt where the user
    # must type the exact value". A pipe cannot satisfy that, and fail-closed
    # makes refusal the required reading — which is also what makes this path
    # effectively unscriptable, as production-safety.md says it should be.
    it "refuses when stdin is not a terminal, rather than skipping the prompt" do
      confirmation = described_class.new(stdin: StringIO.new("AcmeApp\n"), stdout: stdout)

      expect { confirmation.obtain!("AcmeApp", prompt: "danger") }
        .to raise_error(Loadwright::SafetyError, /not a terminal/)
      expect(stdout.string).to be_empty
    end

    # Resolving the phrase is the guard's job: an unresolvable phrase is its own
    # refusal with its own message, not a prompt nobody can answer.
    it "refuses to prompt with an unresolved phrase" do
      confirmation = described_class.new(stdin: terminal("\n"), stdout: stdout)

      expect { confirmation.obtain!(nil, prompt: "danger") }
        .to raise_error(ArgumentError, /requires a resolved phrase/)
      expect { confirmation.obtain!("  ", prompt: "danger") }
        .to raise_error(ArgumentError, /requires a resolved phrase/)
    end
  end
end

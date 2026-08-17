# frozen_string_literal: true

# Test doubles for the safety guard's collaborators.
#
# These are hand-written rather than rspec-mocks doubles for one reason: the
# guard's specs must be able to assert that NO request was issued, and a
# raise-on-call object states that intent in the object itself rather than in a
# `expect(...).not_to receive` that only fails if the example remembers to set
# it up.
module SafetyHelpers
  # Answers a scripted phrase. Records every prompt so a spec can assert the
  # second, heuristics-specific confirmation actually happened.
  class ScriptedConfirmation
    attr_reader :prompts

    def initialize(answers)
      @answers = Array(answers)
      @prompts = []
    end

    def obtain!(phrase, prompt:)
      @prompts << prompt
      answer = @answers.shift
      # nil means "the operator typed nothing", which is a refusal, not a pass.
      return true if answer == :correct || answer == phrase

      raise Loadwright::SafetyError, "refusing to run: confirmation phrase did not match"
    end
  end

  # Never answers. Used to prove a refusal happened BEFORE the prompt — if the
  # guard reaches a prompt it should not have reached, the spec fails loudly
  # rather than passing for the wrong reason.
  class RefusingConfirmation
    def obtain!(*, **)
      raise "the guard reached the confirmation prompt when it should have refused first"
    end
  end

  class ScriptedIdentifier
    def initialize(report: nil, raises: nil)
      @report = report
      @raises = raises
    end

    def identify!(_url)
      raise @raises if @raises

      @report
    end
  end

  # Anything that would issue a request. Registered wherever a spec needs to
  # prove the guard aborted before discovery, seeding, or execution.
  class RaiseOnCall
    def initialize(label) = @label = label

    def method_missing(name, *, **)
      raise "#{@label} was reached (##{name}) after the safety guard should have aborted the run"
    end

    def respond_to_missing?(*) = true
  end

  def identity_report(environment:, url: "http://staging.example.com", enabled_here: true)
    Loadwright::Safety::RemoteTargetIdentifier::Report.new(
      url: url,
      host: URI.parse(url).host,
      environment: environment,
      version: Loadwright::VERSION,
      enabled_here: enabled_here
    )
  end

  # A guard wired entirely from injected collaborators — no Rails, no sockets, no
  # real ENV.
  #
  # `rails_env: nil` is what makes the injected `env:` actually take effect. Without
  # it these specs read ::Rails.env, which examples/sample_app sets to "test" — so
  # every "refuses to run in production" example would silently be running in test
  # and passing for the wrong reason. It did, until this repo grew a fixture app.
  def build_guard(config:, env: {}, rails_env: nil, hostname: "macbook.local",
                  confirmation: nil, identifier: nil, stdout: nil)
    Loadwright::Safety::EnvironmentGuard.new(
      config: config,
      confirmation: confirmation || RefusingConfirmation.new,
      identifier: identifier || ScriptedIdentifier.new(raises: "identifier should not have been consulted"),
      env: env,
      rails_env: rails_env,
      hostname: hostname,
      stdout: stdout || StringIO.new
    )
  end
end

RSpec.configure { |c| c.include SafetyHelpers }

# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Safety
    # Interactive typed confirmation. The phrase is the host application's module
    # name; when it cannot be resolved the production path is refused rather than
    # falling back to a generic phrase that defeats the point.
    #
    # Specified in references/production-safety.md (Layer 3)
    #
    # NON-INTERACTIVE INPUT IS A REFUSAL, not a skip. Layer 3 condition 2 is "an
    # interactive confirmation prompt where the user must type the exact value";
    # a pipe or a CI log cannot satisfy that, and the fail-closed rule makes the
    # conservative reading the required one. This is why the production path is
    # effectively unscriptable, which production-safety.md says it should be
    # ("this whole path should almost never be scripted").
    class Confirmation
      def initialize(stdin: $stdin, stdout: $stdout)
        @stdin = stdin
        @stdout = stdout
      end

      # Raises SafetyError unless the operator types `phrase` exactly.
      #
      # `phrase` must already be resolved; resolving it is the guard's job,
      # because an unresolvable phrase is a refusal with its own distinct
      # message, not a prompt with an empty answer.
      def obtain!(phrase, prompt:)
        raise ArgumentError, "obtain! requires a resolved phrase" if phrase.to_s.strip.empty?

        require_interactive!

        @stdout.puts prompt
        @stdout.print "Type #{phrase} to continue: "
        @stdout.flush

        answer = @stdin.gets

        # EOF. Distinguished from a wrong answer because the cause and the fix
        # are different: no input at all usually means the prompt was piped.
        raise SafetyError, "refusing to run: no confirmation was entered (end of input)" if answer.nil?

        answer = answer.chomp
        return true if answer == phrase

        raise SafetyError,
              "refusing to run: confirmation phrase did not match. Expected #{phrase.inspect}, " \
              "got #{answer.inspect}."
      end

      private

      def require_interactive!
        return if interactive?

        raise SafetyError, <<~MSG.strip
          refusing to run: this run requires an interactive typed confirmation, and standard input
          is not a terminal. Loadwright's production-adjacent path is deliberately not scriptable —
          the typed phrase exists so a human acknowledges the risk in the moment. Run it from a
          terminal, or (much better) point the run at a development or test environment instead.
        MSG
      end

      def interactive?
        @stdin.respond_to?(:tty?) && @stdin.tty?
      end
    end
  end
end

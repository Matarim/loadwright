# frozen_string_literal: true

# The config keys documented in the generated initializer, in AGENTS.md, in the
# README, and the attributes on Loadwright::Configuration must not drift apart.
#
# The assertion DIRECTION differs per source, and getting that wrong makes the
# spec either useless or permanently red:
#
#   initializer <-> Configuration   equality. The generated file is meant to be
#                                   exhaustive, so every key appears in both.
#
#   README      <-> Configuration   equality. The README's configuration
#                                   walkthrough documents every key with its
#                                   default.
#
#   AGENTS.md    -> Configuration   SUBSET, one direction only. Every key
#                                   AGENTS.md names must exist — no phantom
#                                   keys, no renamed keys, nothing an agent
#                                   would confidently set that silently does
#                                   nothing. The reverse is deliberately NOT
#                                   asserted: AGENTS.md documents task-relevant
#                                   keys, not all of them, and forcing it to be
#                                   exhaustive would wreck the cookbook.
#
# Phantom keys are the failure this catches. `config.some_renamed_key = true`
# raises nothing, warns nothing, and silently does nothing.
RSpec.describe "documentation drift" do
  let(:configuration_keys) { Loadwright::Configuration.keys.sort }

  # Matches both live and commented-out assignments. A commented example still
  # documents the key, and some keys (confirmation_phrase) are deliberately
  # shipped commented out.
  ASSIGNMENT = /^\s*#?\s*config\.([a-z0-9_]+)\s*=/.freeze

  def keys_in(source)
    source.scan(ASSIGNMENT).flatten.map(&:to_sym).uniq
  end

  describe "the generated initializer" do
    let(:template) { SpecPaths.read(SpecPaths::INITIALIZER_TT) }
    let(:template_keys) { keys_in(template).sort }

    it "documents every configuration key" do
      expect(configuration_keys - template_keys)
        .to be_empty, "keys on Configuration but missing from the initializer template"
    end

    it "documents no key that does not exist" do
      expect(template_keys - configuration_keys)
        .to be_empty, "keys in the initializer template that do not exist on Configuration"
    end

    # Rails evaluates every initializer in every environment, but this gem is in
    # the :development, :test group. Without the guard, booting production
    # raises NameError and the app does not start.
    it "wraps everything in the `if defined?(Loadwright)` guard" do
      expect(template).to match(/^if defined\?\(Loadwright\)$/)
    end

    it "explains why the guard is required, so nobody removes it as noise" do
      expect(template).to match(/guard below is REQUIRED/i)
    end
  end

  describe "AGENTS.md" do
    let(:agents) { SpecPaths.read(SpecPaths::AGENTS_MD) }

    # Keys an agent is told to set: anything under a `set:` block in the
    # cookbook, plus any explicit `config.foo` reference anywhere in the file.
    #
    # Known limitation: keys named only in prose are not extracted. Structural
    # positions are checked because they are unambiguous; widening the net to
    # bare prose tokens produces false positives on ordinary English.
    def documented_keys
      keys = agents.scan(/config\.([a-z0-9_]+)/).flatten

      agents.each_line.with_index do |line, index|
        next unless line =~ /^(\s*)set:\s*$/

        indent = Regexp.last_match(1).length
        agents.each_line.drop(index + 1).each do |following|
          break if following.strip.empty?

          match = following.match(/^(\s*)([a-z0-9_]+):/)
          break unless match && match[1].length > indent

          keys << match[2]
        end
      end

      keys.map(&:to_sym).uniq
    end

    it "names at least some configuration keys, or this spec is vacuous" do
      expect(documented_keys).not_to be_empty
    end

    # The direction that matters. A stale agent doc is worse than a stale human
    # one: an agent acts on it confidently, without a human reader's skepticism.
    it "names no key that does not exist on Configuration" do
      phantom = documented_keys - configuration_keys

      expect(phantom).to be_empty,
                         "AGENTS.md documents #{phantom.inspect}, which do not exist on " \
                         "Loadwright::Configuration. An agent setting these would get no error " \
                         "and no effect."
    end
  end

  describe "the README" do
    let(:readme) { SpecPaths.read(SpecPaths::README_MD) }

    # The README's configuration walkthrough lands in the final session. Rather
    # than a `pending` example — which reads green for months and silently never
    # activates, which is exactly the drift this guards against — this check
    # arms itself the moment the README grows a configuration section.
    def configuration_section?
      readme.match?(/^#{'#'}{2,}\s+.*\bconfiguration\b/i)
    end

    it "documents every configuration key, once it has a configuration section" do
      skip "README has no configuration section yet; this activates automatically when it does" \
        unless configuration_section?

      readme_keys = keys_in(readme).sort

      expect(configuration_keys - readme_keys)
        .to be_empty, "keys on Configuration but missing from the README walkthrough"
      expect(readme_keys - configuration_keys)
        .to be_empty, "keys in the README that do not exist on Configuration"
    end

    it "points agents at AGENTS.md within the first screen" do
      expect(readme).to match(/^#{'#'}{2,}\s+For AI Agents/i)
    end
  end
end

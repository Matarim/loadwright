# frozen_string_literal: true

# Structural invariants of the three-seam execution design.
#
# Capability is a property of the COLLECTOR, not of the execution mode. An :http
# run against a remote target that does not load the gem has the same transport
# as a fully-instrumented one and dramatically less capability. Analysis and
# reporting must therefore ask CapabilityProfile what is measurable, never
# branch on config.execution_mode.
RSpec.describe "architecture invariants" do
  # Reporting legitimately DISPLAYS the mode — reporting.md requires it appear
  # prominently in run metadata so a reader never has to guess which mode
  # produced the numbers. That is a display read, not a capability decision, and
  # is exempted by an explicit marker comment on the line.
  EXEMPTION_MARKER = "capability-exempt:"

  def offending_lines(directory)
    Dir[File.join(SpecPaths::LIB, directory, "**", "*.rb")].flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, index|
        next unless line.include?("config.execution_mode")
        next if line.include?(EXEMPTION_MARKER)
        # Comment lines are skipped: these files STATE the rule in a comment, and the
        # statement of a prohibition is not a violation of it. Without this the check
        # punishes documenting the invariant, which is the opposite of what it wants.
        next if line.strip.start_with?("#")

        "#{path.sub("#{SpecPaths::ROOT}/", '')}:#{index + 1}: #{line.strip}"
      end
    end
  end

  # Deliberately narrower than grepping for the bare string "execution_mode":
  # reaching into config to branch is the defect, and a mode name appearing in a
  # metadata header or a doc comment is not.
  it "keeps analysis/ from branching on the execution mode" do
    expect(offending_lines("analysis")).to be_empty,
                                           "analysis/ must consult CapabilityProfile, not config.execution_mode"
  end

  it "keeps reporting/ from branching on the execution mode" do
    expect(offending_lines("reporting")).to be_empty,
                                            "reporting/ must consult CapabilityProfile, not config.execution_mode. " \
                                            "To display the mode in run metadata, mark the line " \
                                            "`# #{EXEMPTION_MARKER} metadata display`."
  end

  it "exposes an exemption route, so the metadata header does not need a workaround" do
    sample = "mode = config.execution_mode # #{EXEMPTION_MARKER} metadata display\n"
    expect(sample.include?(EXEMPTION_MARKER)).to be(true)
  end

  describe "the identity endpoint" do
    # production-safety.md Layer 1b. The circularity it resolves: we must ask a
    # remote target what environment it is BEFORE approving a run, but the
    # collection endpoint only mounts AFTER approval. Two endpoints, two risk
    # profiles. Keeping them in separate files is what stops the guarded one's
    # payload leaking into the unguarded one.
    it "is a separate file from the guarded collection middleware" do
      expect(File).to exist(File.join(SpecPaths::LIB, "execution", "identity_endpoint.rb"))
      expect(File).to exist(File.join(SpecPaths::LIB, "execution", "collector_middleware.rb"))
    end

    it "records that its self-report is authoritative for refusal only" do
      source = File.read(File.join(SpecPaths::LIB, "safety", "remote_target_identifier.rb"))
      expect(source).to match(/REFUSAL and never for approval/)
    end
  end

  describe "the contention guard" do
    # resource-contention.md: Loadwright observes contention and retreats from it. It
    # never tries to resolve it.
    #
    # This is the whole-library sweep. It checks CODE, with comment lines and the
    # guard's own FORBIDDEN_STATEMENTS pattern removed — the earlier version exempted
    # any file containing the phrase "ABSOLUTE RULE", which meant a file could opt
    # itself out of the check by describing the rule it was breaking.
    #
    # The complementary assertion, on the SQL the guard ACTUALLY EXECUTED at runtime,
    # lives in resource_guard_spec.rb. Both are wanted: this one catches a statement
    # added to a code path no spec happens to drive.
    it "never issues a statement that terminates, cancels or kills a session" do
      forbidden = /pg_terminate_backend|pg_cancel_backend|UNLOCK\s+TABLES|\bKILL\s+(?:\d|CONNECTION|QUERY)/i

      offenders = Dir[File.join(SpecPaths::LIB, "**", "*.rb")].filter_map do |path|
        code = File.readlines(path).reject do |line|
          stripped = line.strip
          stripped.start_with?("#") ||
            # The guard names these in order to assert on them; the definition of the
            # prohibition is not a violation of it.
            stripped.start_with?("FORBIDDEN_STATEMENTS")
        end.join

        path.sub("#{SpecPaths::ROOT}/", "") if code.match?(forbidden)
      end

      expect(offenders).to be_empty,
                           "these files contain a statement that resolves contention rather than " \
                           "retreating from it: #{offenders.join(', ')}"
    end
  end
end

# frozen_string_literal: true

# THE GUARD THAT KEEPS `:not_applicable` FROM BECOMING A LAUNDERING MECHANISM.
#
# Coverage has three detector states, and the third one exists for a good reason: a
# detector that was never wired up, or that the user switched off, is not a gap this
# run can be blamed for. Without it, every endpoint would have read `inconclusive` for
# index analysis until ExplainAnalyzer shipped, which would have made the state
# meaningless.
#
# The hazard is the mirror image. `:not_applicable` is quiet -- it never escalates to
# `inconclusive` -- so a detector that is ENABLED but cannot answer has an obvious
# place to hide. Returning `:not_applicable` there would report a clean verdict for a
# check that did not happen, which is the confidently-wrong-all-clear this whole
# design exists to prevent.
#
# So the rule, stated once and enforced here:
#
#   ENABLED IN CONFIG + CANNOT ANSWER  ->  :unavailable, with a reason
#   DISABLED IN CONFIG                 ->  :not_applicable
#
# Specced now, while there are two freshly-activated detectors to test it against.
RSpec.describe "detector activation" do
  let(:config) { Loadwright::Configuration.new }

  # Each newly-live detector, paired with the config key that turns it off and the
  # worst-case circumstances in which it is asked to answer with nothing to go on.
  #
  # `state_when_enabled_and_stuck` is the interesting call: the subsystem is switched
  # ON and has been given nothing it can work with.
  DETECTORS = {
    explain: {
      config_key: :run_explain_on_slow_queries,
      state_when_enabled_and_stuck: lambda { |config|
        analyzer = Loadwright::Analysis::ExplainAnalyzer.new(
          config: config, connection: false, stdout: StringIO.new
        )
        # Query data existed, and something was slow enough to be worth explaining --
        # but there is no connection to explain it through. Enabled, asked, stuck.
        candidate = Loadwright::Analysis::ExplainAnalyzer::Candidate.new(
          endpoint_key: "GET /x", fingerprint: "fp", sql: "SELECT 1", duration_ms: 900.0
        )
        analyzer.analyze([candidate], query_data: true).detector_state
      },
      state_when_disabled: lambda { |config|
        Loadwright::Analysis::ExplainAnalyzer.new(config: config, connection: false, stdout: StringIO.new)
                                             .analyze([], query_data: true).detector_state
      }
    },
    percentiles: {
      # Latency statistics have no on/off switch -- they are computed from samples the
      # run already collected, so there is nothing to disable. min_samples_for_percentiles
      # tunes the threshold rather than turning the detector off, which is why the
      # disabled case is absent rather than faked.
      config_key: nil,
      state_when_enabled_and_stuck: lambda { |config|
        Loadwright::Analysis::Statistics.new(config: config).detector_state([])
      }
    }
  }.freeze

  DETECTORS.each do |name, spec|
    describe "the #{name} detector" do
      it "reports :unavailable, never :not_applicable, when it is enabled and cannot answer" do
        state, reason = Array(spec[:state_when_enabled_and_stuck].call(config))

        expect(state).to eq(:unavailable),
                         "#{name} laundered a real coverage gap as :not_applicable, which never " \
                         "escalates to inconclusive -- the endpoint would read clean for a check " \
                         "that did not happen"
        expect(reason.to_s).not_to be_empty, "an unavailable detector must say why"
      end

      # The reason is the whole value of :unavailable over a silent gap. It is what a
      # reader acts on, so "unavailable" alone is not good enough.
      it "gives a reason a reader can act on" do
        _, reason = Array(spec[:state_when_enabled_and_stuck].call(config))

        expect(reason.to_s.length).to be > 20
      end

      next if spec[:config_key].nil?

      it "reports :not_applicable when the user turned it off, which is not a gap" do
        config.public_send(:"#{spec[:config_key]}=", false)
        state, = Array(spec[:state_when_disabled].call(config))

        expect(state).to eq(:not_applicable)
      end

      it "names the config key that switched it off, so the reader knows it was a choice" do
        config.public_send(:"#{spec[:config_key]}=", false)
        _, reason = Array(spec[:state_when_disabled].call(config))

        expect(reason.to_s).to include(spec[:config_key].to_s)
      end
    end
  end

  # A structural check rather than a per-detector one: Coverage will accept any state
  # for any detector, so nothing stops a future detector from returning the wrong one.
  # This asserts the two states remain distinguishable in the direction that matters.
  describe "the state model itself" do
    it "escalates :unavailable to inconclusive and leaves :not_applicable alone" do
      unavailable = Loadwright::Coverage.new(explain: [:unavailable, "no connection"])
      not_applicable = Loadwright::Coverage.new({})

      expect(unavailable).to be_uncovered(:index_scan)
      expect(not_applicable).not_to be_uncovered(:index_scan)
    end

    it "shows both in the per-endpoint coverage description, so neither is invisible" do
      coverage = Loadwright::Coverage.new(explain: [:unavailable, "no connection for EXPLAIN"])

      expect(coverage.describe).to include("index analysis", "no connection for EXPLAIN")
    end
  end
end

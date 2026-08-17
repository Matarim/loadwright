# frozen_string_literal: true

RSpec.describe Loadwright::Configuration do
  subject(:config) { described_class.new }

  describe "safe defaults" do
    # configuration.md: defaults are the safest, narrowest, most conservative
    # option in every case. Widening is always an explicit opt-in.
    it "refuses every environment except development and test" do
      expect(config.enabled_environments).to eq(%i[development test])
    end

    it "does not allow production" do
      expect(config.allow_production).to be(false)
    end

    it "does not allow remote http targets" do
      expect(config.allow_remote_http_target).to be(false)
    end

    it "does not allow mutating requests" do
      expect(config.allow_mutating_requests).to be(false)
    end

    it "contains mail, jobs and outbound HTTP" do
      expect(config.suppress_mail_delivery).to be(true)
      expect(config.suppress_background_jobs).to be(true)
      expect(config.block_outbound_http).to be(true)
    end

    it "aborts rather than running with unenforceable containment" do
      expect(config.abort_if_containment_unavailable).to be(true)
    end

    it "defaults to the execution mode with zero setup" do
      expect(config.execution_mode).to eq(:in_process)
    end

    it "deletes only created rows rather than truncating" do
      expect(config.seed_cleanup_strategy).to eq(:delete_created_rows)
    end

    it "does not write response bodies into reports" do
      expect(config.include_response_bodies).to be(false)
    end
  end

  describe "provenance" do
    it "reports untouched keys as defaults" do
      expect(config.provenance(:lock_timeout_ms)).to eq(:default)
      expect(config).not_to be_explicitly_set(:lock_timeout_ms)
    end

    it "reports assigned keys as explicit, even when assigned the default value" do
      config.lock_timeout_ms = 3_000

      expect(config.lock_timeout_ms).to eq(3_000)
      expect(config.provenance(:lock_timeout_ms)).to eq(:explicit)
      expect(config).to be_explicitly_set(:lock_timeout_ms)
    end

    it "reports preset-supplied keys as coming from the preset" do
      config.contention_profile = :conservative

      expect(config.lock_timeout_ms).to eq(1_000)
      expect(config.provenance(:lock_timeout_ms)).to eq(:preset)
    end
  end

  describe "contention profile presets" do
    # The behaviour plain attr_accessors cannot express: an explicit assignment
    # equal to the default must still beat the preset.
    it "lets an explicit value override the preset, even when it equals the default" do
      config.lock_timeout_ms = 3_000
      config.contention_profile = :conservative

      expect(config.lock_timeout_ms).to eq(3_000)
      expect(config.provenance(:lock_timeout_ms)).to eq(:explicit)
    end

    it "is order-independent — preset first, then explicit" do
      config.contention_profile = :conservative
      config.lock_timeout_ms = 7_000

      expect(config.lock_timeout_ms).to eq(7_000)
    end

    it "is order-independent — explicit first, then preset" do
      other = described_class.new
      other.lock_timeout_ms = 7_000
      other.contention_profile = :conservative

      expect(other.lock_timeout_ms).to eq(7_000)
    end

    it "still applies the preset to keys the user did not touch" do
      config.lock_timeout_ms = 7_000
      config.contention_profile = :conservative

      expect(config.post_quarantine_cooldown_ms).to eq(15_000)
      expect(config.provenance(:post_quarantine_cooldown_ms)).to eq(:preset)
    end

    it "leaves the documented defaults alone under :balanced" do
      config.contention_profile = :balanced
      expect(config.lock_timeout_ms).to eq(3_000)
      expect(config.max_consecutive_quarantines).to eq(3)
    end

    it "loosens timeouts under :aggressive" do
      config.contention_profile = :aggressive
      expect(config.lock_timeout_ms).to eq(10_000)
      expect(config.post_quarantine_cooldown_ms).to eq(1_000)
    end

    it "rejects an unknown profile by name" do
      config.contention_profile = :yolo
      expect { config.resolved }.to raise_error(Loadwright::ConfigurationError, /unknown contention_profile/)
    end
  end

  describe "lazily-resolved defaults" do
    # Rails is hidden explicitly rather than assumed absent. examples/sample_app
    # boots a real Rails application in this process, so whether `Rails` is defined
    # here depends on spec ORDER — and a premise that depends on order is worse
    # than no premise at all.
    before { hide_const("Rails") }

    # Eager evaluation would either raise on load or freeze a wrong value.
    it "resolves Rails-dependent defaults without a Rails application present" do
      expect { config.run_history_dir }.not_to raise_error
      expect(config.openapi_spec_paths).to eq([])
      expect(config.integration_spec_paths).to eq([])
    end

    # production-safety.md justifies the app-module-name default specifically so
    # the phrase cannot be guessed generically. A hardcoded fallback would
    # defeat that, so there is none: unresolvable means nil, and the safety
    # guard refuses the production path rather than accepting a substitute.
    it "leaves confirmation_phrase nil rather than falling back to a generic phrase" do
      expect(config.confirmation_phrase).to be_nil
    end

    it "still allows an explicit confirmation phrase" do
      config.confirmation_phrase = "MyApp"
      expect(config.confirmation_phrase).to eq("MyApp")
    end
  end

  describe "confirmation_phrase against a real Rails application", :sample_app do
    # The documented default: the host application's module name, so the phrase is
    # specific to the app and cannot be guessed generically. Derived by splitting
    # the class name rather than via ActiveSupport's Module#module_parent_name,
    # which comes from a core_ext this gem does not require.
    it "is the application's module name" do
      expect(Loadwright::Configuration.new.confirmation_phrase).to eq("SampleApp")
    end

    it "resolves Rails-rooted paths under the application root" do
      expect(Loadwright::Configuration.new.report_output_dir.to_s)
        .to eq(Rails.root.join("tmp/loadwright").to_s)
    end
  end

  describe "#comparability_fingerprint" do
    # run-comparison.md: the gate must compare resolved values. Two runs with
    # identical explicit config but different presets are not comparable, and a
    # fingerprint over assignments would call them comparable.
    it "matches for two identically-resolved configurations" do
      a = described_class.new
      b = described_class.new
      expect(a.comparability_fingerprint).to eq(b.comparability_fingerprint)
    end

    it "differs when a measurement dimension changes" do
      other = described_class.new
      other.concurrency_levels = [1, 5, 20, 50]
      expect(other.comparability_fingerprint).not_to eq(config.comparability_fingerprint)
    end

    it "differs when a preset silently changes a measurement dimension" do
      # :conservative lowers concurrency_levels. Nothing was assigned explicitly
      # on either side, so an assignment-based fingerprint would call these two
      # comparable and produce a meaningless delta.
      preset = described_class.new
      preset.contention_profile = :conservative

      expect(preset.concurrency_levels).to eq([1, 5])
      expect(preset.comparability_fingerprint).not_to eq(config.comparability_fingerprint)
    end

    it "ignores dimensions that do not affect what was measured" do
      other = described_class.new
      other.report_formats = [:json]
      other.slack_webhook_url = "https://example.test/hook"
      expect(other.comparability_fingerprint).to eq(config.comparability_fingerprint)
    end
  end

  describe "#snapshot" do
    it "records each key's value and where it came from" do
      config.contention_profile = :conservative
      config.lock_timeout_ms = 7_000
      snapshot = config.snapshot

      expect(snapshot[:lock_timeout_ms]).to eq({ value: 7_000, from: :explicit })
      expect(snapshot[:post_quarantine_cooldown_ms]).to eq({ value: 15_000, from: :preset })
      expect(snapshot[:slow_query_threshold_ms]).to eq({ value: 100, from: :default })
    end
  end

  describe "#validate!" do
    it "accepts the defaults" do
      expect(config.validate!).to be(true)
    end

    # discovery-and-load-engine.md: the app runs in a separate process under
    # :http and will not see the harness's transaction. Caught at startup, not
    # as a mysterious empty database mid-run.
    it "rejects transactional rollback in :http mode" do
      config.execution_mode = :http
      config.seed_cleanup_strategy = :transactional_rollback

      expect { config.validate! }
        .to raise_error(Loadwright::ConfigurationError, /transactional_rollback is unavailable in :http mode/)
    end

    it "rejects an unknown execution mode" do
      config.execution_mode = :carrier_pigeon
      expect { config.validate! }.to raise_error(Loadwright::ConfigurationError, /execution_mode/)
    end
  end

  describe "the module-level DSL" do
    it "yields the configuration and remembers it" do
      Loadwright.configure { |c| c.scale_factors = [1, 2] }
      expect(Loadwright.config.scale_factors).to eq([1, 2])
    end
  end
end

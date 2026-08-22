# frozen_string_literal: true

RSpec.describe Loadwright::SideEffects::Containment do
  let(:config) { Loadwright::Configuration.new }
  let(:lifecycle) { Loadwright::Lifecycle.new(stderr: StringIO.new) }
  let(:stdout) { StringIO.new }

  subject(:containment) do
    described_class.new(config: config, lifecycle: lifecycle, stdout: stdout)
  end

  # Minimal stand-ins for ActionMailer::Base and ActiveJob::Base. Defined as real
  # constants because the containment code checks `defined?` — a doubled constant
  # would not exercise the branch that matters.
  def with_action_mailer(delivery_method: :smtp)
    stub_const("ActionMailer::Base", Class.new do
      class << self
        attr_accessor :delivery_method, :perform_deliveries
      end
    end)
    ActionMailer::Base.delivery_method = delivery_method
    ActionMailer::Base.perform_deliveries = true
    ActionMailer::Base
  end

  # ==========================================================================
  # STATE THE ABSENCE, never rely on it. These examples' premise is "ActionMailer /
  # ActiveJob is not loaded", and for a while that held only because those gems were
  # not in the bundle. They are now -- examples/sample_app requires them so the
  # fixture can exercise containment for real -- and once it boots, both constants are
  # defined for every example that runs afterwards. The premise then passes or fails
  # on spec ORDER, which is precisely the failure that silently disabled twenty-two of
  # the safety guard's examples (CLAUDE.md, working conventions).
  # ==========================================================================
  def without_action_mailer = hide_const("ActionMailer::Base")

  def without_active_job = hide_const("ActiveJob::Base")

  def with_active_job
    adapter = Class.new.new
    stub_const("ActiveJob::Base", Class.new do
      class << self
        attr_accessor :queue_adapter
      end
    end)
    ActiveJob::Base.queue_adapter = adapter
    ActiveJob::Base
  end

  describe "mail suppression" do
    it "forces delivery_method to :test and restores it afterwards" do
      mailer = with_action_mailer(delivery_method: :smtp)
      config.block_outbound_http = false
      config.suppress_background_jobs = false

      containment.install!
      expect(mailer.delivery_method).to eq(:test)

      containment.restore!
      expect(mailer.delivery_method).to eq(:smtp)
    end

    # :test collects into deliveries rather than dropping, which makes mail
    # volume per request a countable signal instead of an invisible one.
    it "keeps perform_deliveries on, so mail volume stays countable" do
      mailer = with_action_mailer
      config.block_outbound_http = false
      config.suppress_background_jobs = false

      containment.install!

      expect(mailer.perform_deliveries).to be(true)
    end

    it "reports mail as unenforceable when ActionMailer is not loaded" do
      without_action_mailer
      config.block_outbound_http = false
      config.suppress_background_jobs = false

      expect { containment.install! }.to raise_error(Loadwright::ContainmentError) { |error|
        expect(error.message).to include("ActionMailer is not loaded")
        expect(error.message).to include("custom mailer")
      }
    end

    it "records that the measure was off when the user disabled it" do
      config.suppress_mail_delivery = false
      config.suppress_background_jobs = false
      config.block_outbound_http = false

      containment.install!

      measure = containment.to_h[:measures].find { |m| m[:name] == :mail }
      expect(measure).to include(requested: false, enforced: false)
      expect(containment.to_h[:all_requested_enforced]).to be(true)
    end
  end

  describe "background job suppression" do
    it "forces the queue adapter to :test and restores the original object" do
      job_base = with_active_job
      original = job_base.queue_adapter
      config.suppress_mail_delivery = false
      config.block_outbound_http = false

      containment.install!
      expect(job_base.queue_adapter).to eq(:test)

      containment.restore!
      expect(job_base.queue_adapter).to be(original)
    end

    it "names the bypass routes when ActiveJob is not loaded" do
      without_active_job
      config.suppress_mail_delivery = false
      config.block_outbound_http = false

      expect { containment.install! }.to raise_error(Loadwright::ContainmentError, /Sidekiq::Client.push/)
    end
  end

  describe "outbound HTTP blocking" do
    it "blocks outbound HTTP outside the allowlist and restores webmock afterwards" do
      config.suppress_mail_delivery = false
      config.suppress_background_jobs = false

      containment.install!
      expect(containment).to be_enforced(:outbound_http)

      require "net/http"
      expect { Net::HTTP.get(URI("http://third-party.example.com/charge")) }
        .to raise_error(WebMock::NetConnectNotAllowedError)

      containment.restore!
      expect(WebMock).not_to be_net_connect_allowed
    ensure
      WebMock.disable!
    end

    it "records the allowlist it applied" do
      config.suppress_mail_delivery = false
      config.suppress_background_jobs = false
      config.outbound_http_allowlist = %w[localhost 127.0.0.1 hooks.internal]

      containment.install!

      measure = containment.to_h[:measures].find { |m| m[:name] == :outbound_http }
      expect(measure[:detail]).to include("hooks.internal")
    ensure
      containment.restore!
      WebMock.disable!
    end
  end

  describe "the abort-if-unenforceable path" do
    # Warn-and-continue is the wrong default: the user believes they are
    # contained, and silently not being contained is the failure that mails real
    # customers from a dev box.
    it "aborts the run rather than proceeding unprotected" do
      without_action_mailer
      without_active_job
      config.block_outbound_http = false

      expect { containment.install! }.to raise_error(Loadwright::ContainmentError, /refusing to run/)
    end

    it "names every unenforceable measure at once, not just the first" do
      without_action_mailer
      without_active_job
      config.block_outbound_http = false

      expect { containment.install! }.to raise_error(Loadwright::ContainmentError) { |error|
        expect(error.message).to include("mail:")
        expect(error.message).to include("background_jobs:")
      }
    end

    it "restores anything it had already installed before aborting" do
      mailer = with_action_mailer(delivery_method: :smtp)
      without_active_job
      config.block_outbound_http = false
      # ActiveJob missing -> mail installs, then jobs is unenforceable.

      expect { containment.install! }.to raise_error(Loadwright::ContainmentError)
      expect(mailer.delivery_method).to eq(:smtp)
    end

    it "proceeds with a loud warning when the user explicitly accepts the risk" do
      without_action_mailer
      without_active_job
      config.abort_if_containment_unavailable = false
      config.block_outbound_http = false

      expect { containment.install! }.not_to raise_error
      expect(stdout.string).to include("WARNING running with UNENFORCED containment")
      expect(containment.to_h[:all_requested_enforced]).to be(false)
    end
  end

  describe "teardown registration" do
    # ensure blocks do not run on signals, and Ctrl-C is the state a user will
    # most often interrupt from. A run interrupted mid-sweep must not leave the
    # app's mailer pointed at :test.
    it "registers restoration with Lifecycle, so a signal still restores settings" do
      mailer = with_action_mailer(delivery_method: :smtp)
      config.block_outbound_http = false
      config.suppress_background_jobs = false

      containment.install!
      expect(lifecycle.registered_names).to include("side-effect containment")

      lifecycle.run_teardown!
      expect(mailer.delivery_method).to eq(:smtp)
    end

    it "is idempotent, so the ensure path and the signal path cannot fight" do
      mailer = with_action_mailer(delivery_method: :smtp)
      config.block_outbound_http = false
      config.suppress_background_jobs = false
      containment.install!

      containment.restore!
      mailer.delivery_method = :sendmail
      containment.restore!

      expect(mailer.delivery_method).to eq(:sendmail)
    end

    it "never raises out of restoration, since something else may be unwinding" do
      with_action_mailer
      config.block_outbound_http = false
      config.suppress_background_jobs = false
      containment.install!

      allow(ActionMailer::Base).to receive(:delivery_method=).and_raise("frozen")

      expect { containment.restore! }.not_to raise_error
      expect(stdout.string).to include("could not restore")
    end
  end

  it "refuses a double install rather than stacking restorers" do
    config.suppress_mail_delivery = false
    config.suppress_background_jobs = false
    config.block_outbound_http = false
    containment.install!

    expect { containment.install! }.to raise_error(Loadwright::ConfigurationError, /already installed/)
  end
end

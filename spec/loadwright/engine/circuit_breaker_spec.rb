# frozen_string_literal: true

RSpec.describe Loadwright::Engine::CircuitBreaker do
  let(:config) { Loadwright::Configuration.new }

  subject(:breaker) { described_class.new(config: config) }

  describe "the error-rate abort" do
    it "does not trip on a clean run" do
      50.times { breaker.record_success }

      expect(breaker).not_to be_tripped
      expect(breaker.check!).to be(false)
    end

    it "trips once the error rate crosses max_error_rate_before_abort" do
      # Default threshold is 0.20.
      20.times { breaker.record_success }
      10.times { breaker.record_error }

      expect(breaker).to be_tripped
      expect(breaker.error_rate).to be_within(0.001).of(10 / 30.0)
    end

    it "does not trip exactly at the threshold, only above it" do
      8.times { breaker.record_success }
      2.times { breaker.record_error }

      expect(breaker.error_rate).to eq(0.20)
      expect(breaker).not_to be_tripped
    end

    # Tripping on a 1-of-1 error rate would abort most runs during their first
    # warmup request, which is a worse failure than reacting one cell late.
    it "ignores a tiny sample, so one unlucky first request cannot abort a run" do
      breaker.record_error

      expect(breaker.error_rate).to eq(1.0)
      expect(breaker).not_to be_tripped
    end

    it "raises through the normal unwind path, so cleanup and the partial report still run" do
      20.times { breaker.record_success }
      10.times { breaker.record_error }

      expect { breaker.check! }.to raise_error(Loadwright::RunAborted) { |error|
        expect(error.rung).to eq(:circuit_breaker)
        expect(error.message).to include("circuit breaker tripped")
        expect(error.message).to include("max_error_rate_before_abort")
      }
    end

    it "honours a raised threshold for an endpoint set that legitimately errors" do
      config.max_error_rate_before_abort = 0.9
      10.times { breaker.record_success }
      10.times { breaker.record_error }

      expect(breaker).not_to be_tripped
    end
  end

  describe "contention is excluded from the numerator" do
    # The structural half of resource-contention.md Part 6. A run generating
    # contention errors well above the threshold must not trip the breaker,
    # because the guard is handling them correctly.
    it "does not trip on contention events alone, at any volume" do
      100.times { breaker.record_contention }

      expect(breaker).not_to be_tripped
      expect(breaker.error_rate).to eq(0.0)
      expect(breaker.contention_events).to eq(100)
    end

    it "keeps counting contention toward observations, so real errors are not amplified" do
      # 2 genuine errors among 100 requests is 2%, not 100%, even though 98 of
      # them were contention.
      98.times { breaker.record_contention }
      2.times { breaker.record_error }

      expect(breaker.error_rate).to be_within(0.001).of(0.02)
      expect(breaker).not_to be_tripped
    end

    it "still trips on genuine errors while contention is also happening" do
      50.times { breaker.record_contention }
      20.times { breaker.record_success }
      30.times { breaker.record_error }

      expect(breaker).to be_tripped
    end

    it "reports both counts separately, so neither mechanism hides the other" do
      10.times { breaker.record_success }
      3.times { breaker.record_error }
      7.times { breaker.record_contention }

      expect(breaker.to_h).to include(
        observations: 20,
        errors: 3,
        contention_events: 7,
        contention_excluded_from_error_rate: true,
        threshold: 0.20
      )
    end
  end

  describe "thread safety" do
    # The engine records from every concurrent worker. A lost update here shows
    # up as a run that should have aborted and didn't.
    it "counts correctly under concurrent recording" do
      threads = 8.times.map do
        Thread.new do
          100.times do |i|
            i.even? ? breaker.record_success : breaker.record_error
          end
        end
      end
      threads.each(&:join)

      expect(breaker.observations).to eq(800)
      expect(breaker.errors).to eq(400)
    end
  end

  # FROM A REAL INTEGRATION: one endpoint returned 500 on every request, the breaker
  # tripped at 20.6%, and EIGHT unrelated endpoints were never measured. The breaker
  # was doing its job -- "this endpoint is broken" -- but the consequence was a global
  # abort for a local problem.
  #
  # So concentration is checked before tripping. Errors owned by one endpoint
  # quarantine that endpoint; errors spread ACROSS endpoints still abort the run,
  # which is the case the breaker exists for.
  describe "errors concentrated in one endpoint" do
    def breaker(threshold: 0.2)
      config.max_error_rate_before_abort = threshold
      described_class.new(config: config, minimum_observations: 4)
    end

    it "does not trip when one endpoint owns nearly all the errors" do
      subject = breaker
      6.times { subject.record_success("GET /fine") }
      4.times { subject.record_error("GET /broken") }

      expect(subject).not_to be_tripped
      expect(subject.quarantine_candidate).to eq("GET /broken")
    end

    # The case the breaker is FOR: the whole run is broken, not one endpoint.
    it "still trips when the errors are spread across endpoints" do
      subject = breaker
      2.times { subject.record_success }
      %w[GET /a GET /b GET /c GET /d].each_slice(2) do |verb, path|
        2.times { subject.record_error("#{verb} #{path}") }
      end

      expect(subject).to be_tripped
    end

    it "resumes counting without the quarantined endpoint's errors" do
      subject = breaker
      6.times { subject.record_success("GET /fine") }
      4.times { subject.record_error("GET /broken") }
      subject.quarantine!("GET /broken")

      expect(subject.errors).to eq(0)
      expect(subject).not_to be_tripped
      expect(subject.to_h[:quarantined_endpoints]).to eq(["GET /broken"])
    end

    # After quarantining one, a SECOND endpoint failing must still be able to trip
    # the run -- otherwise this becomes a way to never abort at all.
    it "can still trip after a quarantine, once other endpoints fail too" do
      subject = breaker
      6.times { subject.record_success("GET /fine") }
      4.times { subject.record_error("GET /broken") }
      subject.quarantine!("GET /broken")

      3.times { subject.record_error("GET /also-broken") }
      3.times { subject.record_error("GET /third") }

      expect(subject).to be_tripped
    end

    # A run against a SINGLE endpoint has nothing to protect by carrying on.
    it "trips normally when there is only one endpoint in the run" do
      subject = breaker
      6.times { subject.record_success("GET /only") }
      4.times { subject.record_error("GET /only") }

      expect(subject.quarantine_candidate).to be_nil
      expect(subject).to be_tripped
    end
  end
  # SEVERAL BROKEN ENDPOINTS ARE STILL CONCENTRATION, NOT SPREAD.
  #
  # The share rule asks "does ONE endpoint own 80% of the errors". When a handful are
  # each failing on nearly every request, none of them does -- so nothing was a
  # candidate and the run aborted around them.
  #
  # Observed for real: a user widened included_paths to reach a newly-recovered
  # surface, the breaker tripped at 38%, and every one of those failures was on the
  # OLD surface from endpoints already known to be broken. The run died before it
  # reached the endpoints the widening was for. Adding coverage removed coverage.
  describe "a handful of endpoints each failing on nearly every request" do
    subject(:breaker) { described_class.new(config: config, minimum_observations: 10) }

    # Three broken endpoints among ten, each failing every request; the rest fine.
    # The surface size is declared, as the engine declares it, so the answer does not
    # depend on which endpoints the matrix reached first.
    def run_mixed_surface
      breaker.expected_endpoints = 10
      3.times do |n|
        6.times { breaker.record_error("GET /broken-#{n}") }
      end
      7.times do |n|
        6.times { breaker.record_success("GET /fine-#{n}") }
      end
    end

    it "offers a broken endpoint for quarantine rather than tripping" do
      run_mixed_surface

      expect(breaker.quarantine_candidate).to start_with("GET /broken-")
    end

    it "does not trip while a broken endpoint is still quarantinable" do
      run_mixed_surface

      expect(breaker).not_to be_tripped
    end

    # Quarantine each in turn and the run survives, which is the whole point: the
    # seven healthy endpoints still get measured.
    it "lets the run continue once each broken endpoint is set aside" do
      run_mixed_surface

      3.times do
        candidate = breaker.quarantine_candidate
        break if candidate.nil?

        breaker.quarantine!(candidate)
      end

      expect(breaker).not_to be_tripped
      expect(breaker.quarantined.length).to eq(3)
    end

    # THE ORDER DEPENDENCE, which is the actual complaint. Whether the healthy surface
    # gets measured at all must not depend on whether the broken endpoints happen to be
    # exercised first.
    it "quarantines the same way when the broken endpoints run first" do
      breaker.expected_endpoints = 10
      3.times { |n| 6.times { breaker.record_error("GET /broken-#{n}") } }

      expect(breaker.quarantine_candidate).to start_with("GET /broken-")
      expect(breaker).not_to be_tripped
    end

    it "records why each was quarantined, so a widened allowlist is legible" do
      run_mixed_surface
      breaker.quarantine!(breaker.quarantine_candidate)

      reason = breaker.to_h[:quarantine_reasons].values.first

      expect(reason).to eq(errors: 6, observations: 6)
    end
  end

  # THE CASE THE GLOBAL BREAKER EXISTS FOR. Most of the surface failing is spread --
  # a wrong token, an app that is down -- and quarantining through it one endpoint at
  # a time would keep hammering something that is simply broken.
  describe "most of the surface failing" do
    subject(:breaker) { described_class.new(config: config, minimum_observations: 10) }

    it "trips instead of quarantining its way through the matrix" do
      breaker.expected_endpoints = 8
      6.times do |n|
        6.times { breaker.record_error("GET /broken-#{n}") }
      end
      2.times do |n|
        6.times { breaker.record_success("GET /fine-#{n}") }
      end

      expect(breaker.quarantine_candidate).to be_nil
      expect(breaker).to be_tripped
    end
  end

  # "31 of 81 failed" gives a reader no way to tell whether the failures were spread
  # across the surface or came from three endpoints they already knew about.
  describe "the abort message" do
    subject(:breaker) { described_class.new(config: config, minimum_observations: 10) }

    it "names the endpoints most of the failures came from" do
      breaker.expected_endpoints = 8
      6.times do |n|
        6.times { breaker.record_error("GET /broken-#{n}") }
      end
      2.times { |n| 6.times { breaker.record_success("GET /fine-#{n}") } }

      expect(breaker.trip.message).to include("Most of the failures came from").and include("GET /broken-")
    end
  end

  # An endpoint asked twice is not an endpoint we can call broken.
  describe "too few requests to judge an endpoint" do
    subject(:breaker) { described_class.new(config: config, minimum_observations: 10) }

    it "does not quarantine on a couple of failures" do
      2.times { breaker.record_error("GET /unlucky") }
      2.times { breaker.record_error("GET /also-unlucky") }
      8.times { breaker.record_success("GET /fine") }

      expect(breaker.quarantine_candidate).to be_nil
    end
  end
end

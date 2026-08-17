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
end

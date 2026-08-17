# frozen_string_literal: true

RSpec.describe Loadwright::Execution::RequestMetrics do
  def metrics(**overrides)
    described_class.new(request_id: "req-1", collector: :direct, **overrides)
  end

  describe "every field is a Measurement" do
    # The single most important property of this class. There is no code path that
    # turns an unmeasured quantity into 0, because zero queries reads as a
    # perfectly optimised endpoint.
    it "defaults an unsupplied field to unavailable, not to nil or zero" do
      subject = metrics(query_count: Loadwright::Measurement.value(3))

      expect(subject.query_count).to eq(Loadwright::Measurement.value(3))
      expect(subject.view_runtime_ms).to be_unavailable
      expect(subject.view_runtime_ms.reason).to include("direct collector")
    end

    # So that a field added later is unavailable by default rather than silently
    # nil in every existing collector.
    it "leaves a newly added field unavailable across every collector by construction" do
      described_class::MEASURED_FIELDS.each do |field|
        expect(metrics[field]).to be_a(Loadwright::Measurement)
      end
    end

    it "refuses a bare number, so a collector cannot bypass the type" do
      expect { metrics(query_count: 3) }
        .to raise_error(ArgumentError, /query_count must be a Measurement/)
    end

    it "refuses an unknown metric name, catching a typo rather than dropping it" do
      expect { metrics(querry_count: Loadwright::Measurement.value(1)) }
        .to raise_error(ArgumentError, /unknown metric/)
    end
  end

  describe ".unavailable" do
    it "marks everything unavailable for one stated reason" do
      subject = described_class.unavailable(request_id: "req-1", reason: "no middleware", collector: :external)

      expect(described_class::MEASURED_FIELDS).to all(satisfy { |f| subject[f].unavailable? })
      expect(subject.query_count.reason).to eq("no middleware")
    end

    it "allows the response-derived half to stay available" do
      subject = described_class.unavailable(
        request_id: "req-1", reason: "no middleware", collector: :external,
        except: { mail_deliveries: Loadwright::Measurement.value(0) }
      )

      expect(subject.mail_deliveries).to eq(Loadwright::Measurement.value(0))
      expect(subject.query_count).to be_unavailable
    end
  end

  describe "#duplicate_fingerprints" do
    # The pattern-matching half of N+1 detection. The slope half lives in
    # Analysis::ResponseCorrelator; both are reported, because they catch
    # different failure modes and disagreement between them is informative.
    it "returns fingerprints seen more than once in one request" do
      subject = metrics(
        query_count: Loadwright::Measurement.value(4),
        queries: [
          { fingerprint: "SELECT * FROM comments WHERE post_id = ?" },
          { fingerprint: "SELECT * FROM comments WHERE post_id = ?" },
          { fingerprint: "SELECT * FROM comments WHERE post_id = ?" },
          { fingerprint: "SELECT * FROM posts" }
        ]
      )

      expect(subject.duplicate_fingerprints.keys).to eq(["SELECT * FROM comments WHERE post_id = ?"])
      expect(subject.duplicate_fingerprints.values.first.length).to eq(3)
    end

    it "is empty for a clean request" do
      expect(metrics(queries: [{ fingerprint: "SELECT * FROM posts" }]).duplicate_fingerprints).to be_empty
    end
  end

  describe "#to_h" do
    # A nil in a persisted run record or a report template renders as "0" or "—",
    # both of which read as "measured, and fine". That is the exact confusion
    # Measurement exists to prevent, and serialisation is the one place where the
    # type information would otherwise be lost.
    it "serialises an unavailable field as a reason, never as nil" do
      serialised = metrics(query_count: Loadwright::Measurement.value(3)).to_h

      expect(serialised[:query_count]).to eq({ value: 3 })
      expect(serialised[:view_runtime_ms]).to have_key(:unavailable)
      expect(serialised[:view_runtime_ms][:unavailable]).to be_a(String)
    end

    it "caps the query sample, so one pathological endpoint cannot bloat a record" do
      queries = Array.new(500) { |i| { fingerprint: "SELECT #{i}" } }

      expect(metrics(queries: queries).to_h[:query_sample].length).to eq(50)
    end
  end

  it "is frozen once built" do
    expect(metrics).to be_frozen
  end
end

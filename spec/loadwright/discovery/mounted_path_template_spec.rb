# frozen_string_literal: true

RSpec.describe Loadwright::Discovery::MountedPathTemplate do
  def record(path, template: "/internal/api", verb: "get")
    { "verb" => verb, "template" => template, "path" => path }
  end

  def applied(*records) = described_class.apply(records)

  # FROM A REAL INTEGRATION. A Grape app mounted at /internal/api is ONE Rails route,
  # so route recognition answered "/internal/api" for three distinct endpoints. They
  # merged into one, the survivor was requested at the bare mount point, and it 404'd.
  # The tool recorded a valid request, discarded the part that made it valid, then
  # correctly reported that what it sent did not work.
  describe "a Grape app mounted at a prefix" do
    let(:results) do
      applied(
        record("/internal/api/v2/widgets/wgt-aaaa1111-2222-3333-4444-555566667777/customer"),
        record("/internal/api/v2/widgets/wgt-bbbb1111-2222-3333-4444-555566667777"),
        record("/internal/api/v2/widgets/wgt-cccc1111-2222-3333-4444-555566667777/invoices")
      )
    end

    it "recovers one template per endpoint, not one for the mount point" do
      expect(results.map { |r| r["template"] }).to contain_exactly(
        "/internal/api/v2/widgets/{widget_id}/customer",
        "/internal/api/v2/widgets/{widget_id}",
        "/internal/api/v2/widgets/{widget_id}/invoices"
      )
    end

    it "keeps the concrete id, so path params resolve to a record that exists" do
      customer = results.find { |r| r["template"].end_with?("/customer") }

      expect(customer["path_values"]).to eq("widget_id" => "wgt-aaaa1111-2222-3333-4444-555566667777")
    end

    it "marks them inferred, so the report can say where the template came from" do
      expect(results).to all(include("inferred_template" => true))
    end
  end

  # THE TRAP THIS AVOIDS. Sibling endpoints differ in exactly the way a "segments
  # that vary between recordings" rule looks for -- `/customer` against
  # `/invoices` -- so that rule merges two real endpoints into
  # one that is neither. Only ID SHAPE promotes a segment.
  it "does not merge sibling endpoints that differ by a route name" do
    results = applied(
      record("/internal/api/widgets/wgt-dddd1111-2222-3333-4444-555566667777/customer"),
      record("/internal/api/widgets/wgt-eeee1111-2222-3333-4444-555566667777/payments")
    )

    expect(results.map { |r| r["template"] }.uniq.length).to eq(2)
  end

  describe "id shapes it recognises" do
    {
      "42" => "numeric ids",
      "3f2504e0-4f89-11d3-9a0c-0305e82c3301" => "uuids",
      "wgt-aaaa1111-2222-3333-4444-555566667777" => "prefixed uuids",
      "cus_1a2b3c4d5e6f7a8b" => "prefixed opaque ids",
      "01ARZ3NDEKTSV4RRFFQ69G5FAV" => "ulids"
    }.each do |segment, description|
      it "promotes #{description}" do
        results = applied(record("/internal/api/things/#{segment}"))

        expect(results.first["template"]).to eq("/internal/api/things/{thing_id}")
      end
    end

    it "leaves ordinary route segments alone" do
      results = applied(record("/internal/api/things/search"))

      expect(results.first["template"]).to eq("/internal/api/things/search")
    end
  end

  describe "records the router resolved properly" do
    it "leaves a normal Rails template untouched" do
      results = applied(record("/api/v1/posts/1", template: "/api/v1/posts/{id}"))

      expect(results.first["template"]).to eq("/api/v1/posts/{id}")
      expect(results.first).not_to have_key("inferred_template")
    end

    it "leaves an exact match untouched" do
      results = applied(record("/api/v1/posts", template: "/api/v1/posts"))

      expect(results.first["template"]).to eq("/api/v1/posts")
    end

    # A prefix that is not a PATH prefix is a coincidence, not a mount.
    it "does not treat a shared string prefix as a mount point" do
      results = applied(record("/api/v1/postscript", template: "/api/v1/posts"))

      expect(results.first["template"]).to eq("/api/v1/posts")
    end
  end
end

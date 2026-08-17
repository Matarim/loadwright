# frozen_string_literal: true

RSpec.describe Loadwright::Analysis::SerializerAttribution do
  let(:config) { Loadwright::Configuration.new }

  subject(:attribution) { described_class.new(config: config) }

  def call_site(path:, line: 12, label: "comments_count")
    { path: path, line: line, label: label }
  end

  describe "#attribute" do
    # The value of this class in one line: "N+1 originates in serializer
    # app/serializers/post_serializer.rb#comments_count" is actionable, while a raw
    # stack trace is homework.
    it "names the serializer, the file and the method" do
      result = attribution.attribute(call_site(path: "/Users/dev/myapp/app/serializers/post_serializer.rb"))

      expect(result.kind).to eq(:active_model_serializer)
      expect(result.describe).to eq("originates in serializer app/serializers/post_serializer.rb#comments_count:12")
    end

    # An absolute path from someone else's machine is noise in a report.
    it "reports the path relative to the app root" do
      result = attribution.attribute(call_site(path: "/very/long/ci/path/app/models/post.rb"))

      expect(result.short_path).to eq("app/models/post.rb")
    end

    {
      "/app/serializers/post_serializer.rb" => :active_model_serializer,
      "/app/blueprints/post_blueprint.rb" => :blueprinter,
      "/app/views/api/v1/posts/index.json.jbuilder" => :jbuilder,
      "/app/views/posts/_post.html.erb" => :view,
      "/app/presenters/post_presenter.rb" => :presenter,
      "/app/decorators/post_decorator.rb" => :presenter,
      "/app/models/post.rb" => :model,
      "/app/controllers/api/v1/posts_controller.rb" => :controller
    }.each do |path, kind|
      it "attributes #{path} to #{kind}" do
        expect(attribution.attribute(call_site(path: path)).kind).to eq(kind)
      end
    end

    # A Jbuilder template lives under app/views, so ordering decides which layer wins.
    it "prefers the more specific layer when a path matches two" do
      result = attribution.attribute(call_site(path: "/app/views/posts/index.json.jbuilder"))

      expect(result.kind).to eq(:jbuilder)
    end

    it "recognises an as_json override from the frame label" do
      result = attribution.attribute({ path: "/somewhere/odd/post.rb", label: "as_json" })

      expect(result.kind).to eq(:as_json)
    end

    describe "which layers count as the serialisation layer" do
      # This is the distinction that drives AGENTS.md §9.2's advice: redirect the user
      # AWAY from query optimisation when the N+1 is in serialisation.
      it "treats template and presenter layers as serialisation" do
        %w[/app/serializers/x.rb /app/blueprints/x.rb /app/views/x.json.jbuilder
           /app/presenters/x.rb].each do |path|
          expect(attribution.attribute(call_site(path: path))).to be_serializer, path
        end
      end

      it "does not treat a model or controller as serialisation" do
        %w[/app/models/post.rb /app/controllers/posts_controller.rb].each do |path|
          expect(attribution.attribute(call_site(path: path))).not_to be_serializer, path
        end
      end
    end

    # A wrong attribution sends the developer to the wrong file, which is worse than
    # sending them nowhere.
    describe "when it cannot attribute" do
      it "returns nil rather than guessing for an unrecognised path" do
        expect(attribution.attribute(call_site(path: "/opt/vendor/something.rb"))).to be_nil
      end

      it "returns nil for a missing call site" do
        expect(attribution.attribute(nil)).to be_nil
        expect(attribution.attribute({})).to be_nil
      end

      it "returns nil when the user turned attribution off" do
        config.serializer_attribution = false

        expect(attribution.attribute(call_site(path: "/app/serializers/post_serializer.rb"))).to be_nil
      end
    end

    it "accepts string keys, since the call site round-trips through JSON in :http mode" do
      result = attribution.attribute("path" => "/app/serializers/post_serializer.rb", "line" => 9,
                                     "label" => "comments_count")

      expect(result.line).to eq(9)
      expect(result.kind).to eq(:active_model_serializer)
    end

    it "handles a qualified frame label from newer Rubies" do
      result = attribution.attribute(call_site(path: "/app/serializers/post_serializer.rb",
                                               label: "PostSerializer#comments_count"))

      expect(result.method_label).to eq("comments_count")
    end
  end

  describe "#annotate" do
    it "turns a correlator finding into a one-line attribution" do
      finding = Loadwright::Analysis::ResponseCorrelator::Finding.new(
        kind: :n_plus_one_pattern_match, confidence: :high, detail: "ran 25 times",
        evidence: { call_site: call_site(path: "/app/serializers/post_serializer.rb") }
      )

      expect(attribution.annotate(finding)).to include("originates in serializer app/serializers/post_serializer.rb")
    end

    it "is nil for a finding with no call site" do
      finding = Loadwright::Analysis::ResponseCorrelator::Finding.new(
        kind: :missing_pagination, confidence: :high, detail: "grows", evidence: { seeded: 10 }
      )

      expect(attribution.annotate(finding)).to be_nil
    end
  end

  describe "#to_h" do
    it "serialises for the report" do
      audit = attribution.attribute(call_site(path: "/app/serializers/post_serializer.rb")).to_h

      expect(audit).to include(
        kind: :active_model_serializer, path: "app/serializers/post_serializer.rb",
        line: 12, method: "comments_count", serializer: true
      )
      expect(audit[:description]).to include("originates in serializer")
    end
  end
end

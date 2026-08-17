# frozen_string_literal: true

module Loadwright
  module Analysis
    # Attributes an N+1 to the serializer/template layer when its call site points
    # there.
    #
    # WHY THIS IS WORTH A CLASS. Serializer-level N+1s are the most commonly missed
    # kind in API apps, precisely because the controller code looks clean — the
    # developer reads `Post.includes(:comments)` in the controller, concludes the
    # query structure is fine, and never looks at the serializer that calls
    # `post.comments.count` per record.
    #
    # And the output difference is large: "N+1 originates in
    # PostSerializer#comments_count" is actionable, while a raw stack trace is
    # homework. That is the entire value here — same finding, different sentence.
    class SerializerAttribution
      # Ordered most specific first, so a Jbuilder template inside an app/views path
      # is attributed to Jbuilder rather than to the generic view layer.
      LAYERS = [
        { kind: :active_model_serializer, pattern: %r{/app/serializers/}, label: "serializer" },
        { kind: :blueprinter, pattern: %r{/app/blueprints/}, label: "blueprint" },
        { kind: :jbuilder, pattern: /\.json\.jbuilder\z/, label: "Jbuilder template" },
        { kind: :view, pattern: %r{/app/views/}, label: "view template" },
        { kind: :presenter, pattern: %r{/app/(presenters|decorators|representers)/}, label: "presenter" },
        { kind: :as_json, pattern: /\Aas_json\z|#as_json/, label: "as_json override", match: :label },
        { kind: :model, pattern: %r{/app/models/}, label: "model" },
        { kind: :controller, pattern: %r{/app/controllers/}, label: "controller" }
      ].freeze

      Attribution = Struct.new(:kind, :label, :path, :line, :method_label, keyword_init: true) do
        # The sentence that goes in the finding.
        def describe
          location = method_label ? "#{short_path}##{method_label}" : short_path
          "originates in #{label} #{location}#{line ? ":#{line}" : ''}"
        end

        def short_path
          return path if path.nil?

          # Relative to the app root where possible: an absolute path from someone
          # else's machine is noise in a report.
          path.sub(%r{\A.*?/(app|lib)/}, '\1/')
        end

        def serializer? = %i[active_model_serializer blueprinter jbuilder view presenter as_json].include?(kind)

        def to_h
          { kind: kind, label: label, path: short_path, line: line, method: method_label,
            description: describe, serializer: serializer? }
        end
      end

      def initialize(config: Loadwright.configuration)
        @config = config
      end

      def enabled? = @config.serializer_attribution

      # `call_site` is the hash QueryTracker captured: { path:, line:, label: }.
      # Returns nil when attribution is off or there is nothing to attribute — nil
      # rather than a guess, because a wrong attribution sends the developer to the
      # wrong file, which is worse than sending them nowhere.
      def attribute(call_site)
        return nil unless enabled?
        return nil if call_site.nil?

        path = call_site[:path] || call_site["path"]
        label = call_site[:label] || call_site["label"]
        return nil if path.nil? && label.nil?

        layer = LAYERS.find do |candidate|
          subject = candidate[:match] == :label ? label.to_s : path.to_s
          subject.match?(candidate[:pattern])
        end
        return nil if layer.nil?

        Attribution.new(
          kind: layer[:kind],
          label: layer[:label],
          path: path,
          line: call_site[:line] || call_site["line"],
          method_label: method_name(label)
        )
      end

      # Given a finding's evidence, returns the attribution sentence to append, or nil.
      def annotate(finding)
        call_site = finding.evidence.is_a?(Hash) ? finding.evidence[:call_site] : nil
        attribution = attribute(call_site)
        return nil if attribution.nil?

        attribution.describe
      end

      private

      # Ruby 3.4+ gives qualified labels like "PostSerializer#comments_count"; earlier
      # versions give just the method name. Both reduce to the method.
      def method_name(label)
        return nil if label.nil?

        label.to_s.split(/[#.]/).last
      end
    end
  end
end

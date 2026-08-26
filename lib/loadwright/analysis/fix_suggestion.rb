# frozen_string_literal: true

module Loadwright
  module Analysis
    # The likely fix for a repeated query, from its shape.
    #
    # `includes` does NOT fix a repeated COUNT -- preloading still counts with a
    # query unless the code stops calling `.count` -- so that case suggests a counter
    # cache instead. Do not "simplify" it back to `includes`.
    #
    # Suggestions never change an outcome state or the exit code, and an unrecognised
    # shape returns nil rather than a guess.
    module FixSuggestion
      # `SELECT COUNT(*) FROM "posts" WHERE "posts"."author_id" = ?`
      COUNT_PER_RECORD = /\ASELECT\s+COUNT\(.*?\)\s+FROM\s+[`"']?(\w+)[`"']?.*?WHERE.*?[`"']?\w+[`"']?\.?[`"']?(\w+_id)[`"']?\s*=/im

      # `SELECT "comments".* FROM "comments" WHERE "comments"."post_id" = ?`
      CHILDREN_PER_RECORD = /\ASELECT\s+.*?\s+FROM\s+[`"']?(\w+)[`"']?.*?WHERE.*?[`"']?\w+[`"']?\.?[`"']?(\w+_id)[`"']?\s*=/im

      # `SELECT "authors".* FROM "authors" WHERE "authors"."id" = ?`
      PARENT_PER_RECORD = /\ASELECT\s+.*?\s+FROM\s+[`"']?(\w+)[`"']?.*?WHERE\s+[`"']?\w+[`"']?\.?[`"']?id[`"']?\s*=/im

      # `SELECT 1 AS one FROM "users" WHERE "users"."email" = ? LIMIT ?`
      EXISTENCE_PER_RECORD = /\ASELECT\s+1\s+AS\s+one\s+FROM\s+[`"']?(\w+)[`"']?/im

      module_function

      # Returns a suggestion string, or nil when the shape is not one we recognise.
      def for(fingerprint)
        sql = fingerprint.to_s.strip
        return nil if sql.empty?

        # Order matters: COUNT and the `SELECT 1 AS one` existence probe are both
        # narrower than the general child-rows shape, which would otherwise swallow
        # them and give the wrong advice.
        count_suggestion(sql) ||
          existence_suggestion(sql) ||
          parent_suggestion(sql) ||
          children_suggestion(sql)
      end

      def count_suggestion(sql)
        match = COUNT_PER_RECORD.match(sql)
        return nil unless match

        table, foreign_key = match.captures
        owner = foreign_key.sub(/_id\z/, "")

        "One COUNT per record. `includes` will NOT remove this — a preloaded " \
          "association is still counted with a query unless the code stops counting. " \
          "Either add a counter cache (`belongs_to :#{owner}, counter_cache: true` on " \
          "the #{table} model, plus a `#{table}_count` column), or preload #{table} and " \
          "use `.size` on the loaded collection instead of `.count`."
      end

      def existence_suggestion(sql)
        match = EXISTENCE_PER_RECORD.match(sql)
        return nil unless match

        "One existence check per record against `#{match.captures.first}` — usually an " \
          "`exists?`, a `present?` on an unloaded association, or a uniqueness " \
          "validation firing per row. Preload the association, or hoist the check out " \
          "of the loop and compare against a set you loaded once."
      end

      def parent_suggestion(sql)
        match = PARENT_PER_RECORD.match(sql)
        return nil unless match

        table = match.captures.first
        association = singularize(table)

        "One lookup per record by primary key against `#{table}` — the signature of a " \
          "`belongs_to` being walked inside a loop. Preload it: `includes(:#{association})` " \
          "on the query that loads the records you are iterating."
      end

      def children_suggestion(sql)
        match = CHILDREN_PER_RECORD.match(sql)
        return nil unless match

        table = match.captures.first

        "One query per record against `#{table}` — the signature of an unpreloaded " \
          "association. Add `includes(:#{table})` to the query that loads the records " \
          "you are iterating (the association name may differ from the table name)."
      end

      # Deliberately not ActiveSupport's inflector: this runs against a fingerprint,
      # the answer only ever appears inside a suggestion, and loading an inflection
      # ruleset to guess a name we already hedge about is not worth the coupling.
      def singularize(table)
        return table.sub(/ies\z/, "y") if table.end_with?("ies")
        return table.sub(/ses\z/, "s") if table.end_with?("ses")
        return table.chomp("s") if table.end_with?("s")

        table
      end
    end
  end
end

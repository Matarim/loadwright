# frozen_string_literal: true

module Loadwright
  module Analysis
    # Turns "the same query ran 130 times" into "here is the shape of the fix".
    #
    # The report already names the repeated query and the file and line it came from,
    # which is most of the diagnosis. What it did not do is close the last gap: the
    # reader still has to recognise WHICH kind of N+1 this is, and the kinds have
    # different fixes. Getting that wrong wastes an afternoon on the wrong change.
    #
    # THE ONE THAT MATTERS MOST, and that most advice gets wrong: `includes` does not
    # fix a repeated COUNT. Preloading the association still issues a COUNT per record
    # unless the code stops counting -- so the fix is a counter cache, or loading the
    # records and using `size` on the loaded collection. Telling someone to add
    # `includes(:posts)` to fix `SELECT COUNT(*) FROM posts WHERE author_id = ?` sends
    # them to make a change that does not help, and then to distrust the tool.
    #
    # SUGGESTIONS, NOT VERDICTS. This reads a normalised query shape; it has no idea
    # what the surrounding code intends. So it never changes an outcome state, never
    # contributes to an exit code, and is phrased as a starting point. Where the shape
    # is not one it recognises, it says nothing at all rather than guessing -- an
    # invented fix is worse than none, and this is the part of a report a reader is
    # most likely to act on without checking.
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

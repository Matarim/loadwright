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
      #
      # `scaling` is what the run OBSERVED about the repeat, and it changes the advice
      # rather than decorating it -- see fixed_repeat_suggestion. :unknown is the
      # honest default, and it produces the same advice this method always gave.
      def for(fingerprint, repeats: nil, scaling: :unknown)
        sql = fingerprint.to_s.strip
        return nil if sql.empty?

        # Order matters: COUNT and the `SELECT 1 AS one` existence probe are both
        # narrower than the general child-rows shape, which would otherwise swallow
        # them and give the wrong advice.
        return fixed_repeat_suggestion(sql, repeats) if scaling == :fixed && lookup_shape?(sql)

        count_suggestion(sql) ||
          existence_suggestion(sql) ||
          parent_suggestion(sql) ||
          children_suggestion(sql)
      end

      # A COUNT that repeats is a counter-cache question whether or not it scales, so
      # the fixed-repeat advice covers the two LOOKUP shapes only.
      def lookup_shape?(sql)
        return false if COUNT_PER_RECORD.match?(sql)

        PARENT_PER_RECORD.match?(sql) || CHILDREN_PER_RECORD.match?(sql)
      end

      # THE SAME ROW N TIMES IS NOT N ROWS ONE AT A TIME, and `includes` only fixes the
      # second one. A request that loads a record to route to itself and then finds it
      # again four times down the call chain has nothing to preload -- the row is
      # already in memory.
      #
      # The two are distinguishable from data the run already has: a per-record N+1
      # issues more queries as the endpoint returns more records, and a fixed
      # multiplier does not. This branch is only taken where that flatness was
      # actually MEASURED across cells that returned different numbers of records; an
      # unmeasured repeat falls through to the general advice rather than guessing.
      def fixed_repeat_suggestion(sql, repeats)
        table = (PARENT_PER_RECORD.match(sql) || CHILDREN_PER_RECORD.match(sql)).captures.first
        times = repeats ? "#{repeats} times" : "several times"

        "The same query against `#{table}` ran #{times} in one request, and the query count did NOT " \
          "grow when the endpoint returned more records -- so this is a fixed number of repeats per " \
          "request, not one query per record. `includes` will not help: nothing here is being iterated, " \
          "and the row is very likely already loaded (routing to this endpoint had to find it). Pass the " \
          "loaded object down the call chain, or memoize the lookup, rather than preloading. Worth fixing " \
          "as waste on every request, but it will not get worse as your data grows."
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
          "on the query that loads the records you are iterating (the association name may " \
          "differ from the table name)."
      end

      def children_suggestion(sql)
        match = CHILDREN_PER_RECORD.match(sql)
        return nil unless match

        table = match.captures.first

        "One query per record against `#{table}` — the signature of an unpreloaded " \
          "association. Add `includes(:#{table})` to the query that loads the records " \
          "you are iterating (the association name may differ from the table name)."
      end

      # ACTIVESUPPORT'S INFLECTOR, and the comment that used to sit here argued the
      # opposite -- that loading an inflection ruleset to guess a name we already hedge
      # about was not worth the coupling. The hand-rolled rules it defended turned a
      # table ending in "ses" into a non-word by stripping the "es": following the
      # suggestion verbatim raised ActiveRecord::AssociationNotFoundError. A hedge does
      # not rescue advice that cannot be typed.
      #
      # There is no coupling to weigh anyway: activesupport is a hard dependency, and
      # going through the host's inflector means a host that registered its own
      # irregular inflection gets its own answer rather than ours.
      def singularize(table)
        require "active_support/core_ext/string/inflections"
        table.singularize
      rescue StandardError, LoadError
        table.end_with?("ies") ? table.sub(/ies\z/, "y") : table.chomp("s")
      end
    end
  end
end

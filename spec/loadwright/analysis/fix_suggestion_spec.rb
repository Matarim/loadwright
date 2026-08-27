# frozen_string_literal: true

RSpec.describe Loadwright::Analysis::FixSuggestion do
  # `:scaling` is the situation preload advice belongs to -- the run measured the
  # query count growing as more records came back. Passing it explicitly keeps these
  # examples about SHAPE RECOGNITION, which is what they are for, rather than about
  # what the classifier does when it has nothing to go on (see "when nothing could be
  # measured either way", below).
  def suggest(sql) = described_class.for(sql, scaling: :scaling)

  # THE ONE THIS EXISTS FOR. Almost every piece of N+1 advice says "add includes",
  # and for a repeated COUNT that is wrong: a preloaded association is still counted
  # with a query unless the code stops calling `.count`. Sending someone to make a
  # change that does not help is worse than saying nothing, because they then
  # distrust the finding as well as the fix.
  describe "a COUNT per record" do
    let(:sql) { %(SELECT COUNT(*) FROM "posts" WHERE "posts"."author_id" = ?) }

    it "does not tell the reader to add includes" do
      expect(suggest(sql)).to include("`includes` will NOT remove this")
    end

    it "names the counter cache, with the column it needs" do
      expect(suggest(sql)).to include("counter_cache: true")
      expect(suggest(sql)).to include("posts_count")
    end

    it "offers the alternative that does work, for code that cannot add a column" do
      expect(suggest(sql)).to include(".size")
    end
  end

  describe "a child collection loaded per record" do
    it "suggests preloading, and admits the association name is a guess" do
      suggestion = suggest(%(SELECT "comments".* FROM "comments" WHERE "comments"."post_id" = ?))

      expect(suggestion).to include("includes(:comments)")
      expect(suggestion).to include("may differ from the table name")
    end
  end

  describe "a belongs_to walked in a loop" do
    it "recognises the lookup-by-primary-key shape and singularises the table" do
      suggestion = suggest(%(SELECT "authors".* FROM "authors" WHERE "authors"."id" = ?))

      expect(suggestion).to include("belongs_to")
      expect(suggestion).to include("includes(:author)")
    end
  end

  describe "an existence check per record" do
    it "is not mistaken for an unpreloaded association" do
      suggestion = suggest(%(SELECT 1 AS one FROM "users" WHERE "users"."email" = ? LIMIT ?))

      expect(suggestion).to include("existence check")
      expect(suggestion).to include("uniqueness validation")
    end
  end

  # SILENCE IS A VALID ANSWER. This reads a normalised query shape and knows nothing
  # about the surrounding code, so a shape it does not recognise gets no suggestion
  # rather than an invented one. This is the part of a report a reader is most likely
  # to act on without checking.
  describe "a shape it does not recognise" do
    [
      %(SELECT "posts".* FROM "posts" ORDER BY "posts"."id" ASC LIMIT ?),
      %(UPDATE "posts" SET "title" = ? WHERE "posts"."id" = ?),
      %(BEGIN),
      ""
    ].each do |sql|
      it "says nothing about #{sql.empty? ? 'an empty fingerprint' : sql[0, 40]}" do
        expect(suggest(sql)).to be_nil
      end
    end
  end

  it "handles MySQL backticks as well as double quotes" do
    expect(suggest("SELECT `comments`.* FROM `comments` WHERE `comments`.`post_id` = ?"))
      .to include("includes(:comments)")
  end

  describe "singularising for the association name" do
    { "authors" => "author", "categories" => "category", "addresses" => "address" }.each do |table, singular|
      it "turns #{table} into #{singular}" do
        expect(described_class.singularize(table)).to eq(singular)
      end
    end
  end

  # A TABLE ENDING IN "ses". The hand-rolled rules stripped the trailing "es" and
  # produced a non-word, so following the suggestion verbatim raised
  # ActiveRecord::AssociationNotFoundError -- on three of five findings in one real
  # run. The advice underneath was right; a symbol that cannot be typed made a reader
  # discount the rest of it.
  describe "singularising a table name" do
    it "does not invent a non-word out of a plural ending in 'ses'" do
      suggestion = described_class.for('SELECT "warehouses".* FROM "warehouses" WHERE "warehouses"."id" = ?')

      expect(suggestion).to include("includes(:warehouse)")
    end

    it "still handles the ordinary plurals" do
      expect(described_class.for('SELECT "categories".* FROM "categories" WHERE "categories"."id" = ?'))
        .to include("includes(:category)")
    end
  end

  # THE SAME ROW N TIMES IS NOT N ROWS ONE AT A TIME. `includes` fixes the second and
  # does nothing for the first, where the row is already in memory and is simply being
  # found again.
  describe "a repeat the run measured as flat" do
    let(:sql) { 'SELECT "warehouses".* FROM "warehouses" WHERE "warehouses"."id" = ?' }

    it "says the record is already loaded rather than telling you to preload it" do
      suggestion = described_class.for(sql, repeats: 4, scaling: :fixed)

      expect(suggestion).to include("Pass the loaded object down").and include("4 times")
      expect(suggestion).not_to include("includes(")
    end

    it "gives the preloading advice when the repeat was measured to scale" do
      expect(described_class.for(sql, repeats: 4, scaling: :scaling)).to include("includes(:warehouse)")
    end

    # Flatness that was never measured is not flatness -- and neither is scaling, so
    # the unmeasured case gets neither verdict. See "when nothing could be measured
    # either way" below.
    it "claims neither when nothing was measured" do
      expect(described_class.for(sql, repeats: 4)).to include("could not tell which kind of repeat")
    end

    # A repeated COUNT is a counter-cache question whether or not it scales, and
    # `includes` is the wrong advice for it in both directions.
    it "leaves a repeated COUNT to the counter-cache advice" do
      count_sql = 'SELECT COUNT(*) FROM "warehouses" WHERE "warehouses"."depot_id" = ?'

      expect(described_class.for(count_sql, repeats: 4, scaling: :fixed)).to include("counter cache")
    end
  end

  # ABSTAINING FROM THE CLASSIFICATION AND THEN GIVING CONFIDENT ADVICE is the same
  # mistake as a confidently wrong all-clear, one level down. In one real run the
  # classifier correctly declined on all seven findings -- and all seven then carried
  # preload advice, which was the wrong fix for every one of them.
  describe "when nothing could be measured either way" do
    let(:sql) { 'SELECT "warehouses".* FROM "warehouses" WHERE "warehouses"."id" = ?' }

    it "names both branches rather than choosing one" do
      suggestion = described_class.for(sql, repeats: 4, scaling: :unknown)

      expect(suggestion).to include("could not tell which kind of repeat")
      expect(suggestion).to include("includes(:warehouse)").and include("pass the loaded object down")
    end

    it "says what would answer the question" do
      expect(described_class.for(sql, scaling: :unknown)).to include("Vary scale_factors")
    end
  end

  # The weaker denominator, named as such: a paginated collection is flat against
  # seeded scale by construction, which is exactly what a per-record N+1 hiding behind
  # pagination looks like.
  describe "a repeat measured flat against seeded scale only" do
    let(:sql) { 'SELECT "warehouses".* FROM "warehouses" WHERE "warehouses"."id" = ?' }

    it "gives the fixed-repeat advice" do
      expect(described_class.for(sql, repeats: 4, scaling: :fixed_by_seed_scale))
        .to include("pass the loaded object down").or include("Pass the loaded object down")
    end

    it "names the assumption it rests on rather than hiding it" do
      suggestion = described_class.for(sql, repeats: 4, scaling: :fixed_by_seed_scale)

      expect(suggestion).to include("PAGINATED")
    end
  end
end

# frozen_string_literal: true

RSpec.describe Loadwright::Analysis::FixSuggestion do
  def suggest(sql) = described_class.for(sql)

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
end

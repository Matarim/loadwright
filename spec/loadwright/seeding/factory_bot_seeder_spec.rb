# frozen_string_literal: true

# Runs against examples/sample_app with a real database, because every rule this
# class enforces is about what actually happens to rows — and a mocked FactoryBot
# cannot collide on a unique index.
RSpec.describe Loadwright::Seeding::FactoryBotSeeder, :sample_app do
  let(:config) { Loadwright::Configuration.new }
  let(:lifecycle) { Loadwright::Lifecycle.new(stderr: StringIO.new) }
  let(:stdout) { StringIO.new }

  subject(:seeder) do
    described_class.new(config: config, lifecycle: lifecycle, stdout: stdout)
  end

  describe "#seed!" do
    it "creates records through the app's own factories at the requested scale" do
      config.factory_map = { "post" => { factory: :post } }

      seeder.seed!(10)

      expect(Post.count).to eq(10)
    end

    it "returns the id map path-param resolution consumes" do
      config.factory_map = { "post" => { factory: :post } }

      ids = seeder.seed!(3)

      expect(ids["post"].length).to eq(3)
      expect(ids["post"]).to eq(Post.order(:id).pluck(:id))
    end

    it "honours a trait, which is how a scope mismatch gets fixed" do
      config.factory_map = { "post" => { factory: :post, trait: :with_comments } }

      seeder.seed!(4)

      expect(Comment.count).to eq(12)
    end

    it "accepts a bare factory name as shorthand" do
      config.factory_map = { "post" => :post }

      expect { seeder.seed!(2) }.to change(Post, :count).by(2)
    end

    it "seeds several resources" do
      config.factory_map = { "author" => :author, "post" => :post }

      seeder.seed!(3)

      expect([Author.count, Post.count]).to eq([6, 3]) # each post builds its own author
    end

    it "is a no-op with an empty factory_map" do
      expect(seeder.seed!(100)).to eq({})
      expect(Post.count).to eq(0)
    end

    it "is a no-op when factory_bot_enabled is false" do
      config.factory_bot_enabled = false
      config.factory_map = { "post" => :post }

      expect(seeder.seed!(5)).to eq({})
    end
  end

  describe "batching" do
    # create_list(:post, 200) with callbacks, counter caches or search-index hooks
    # can lock the table or exhaust the pool by itself.
    it "creates in batches of seed_batch_size rather than one giant call" do
      config.factory_map = { "post" => :post }
      config.seed_batch_size = 4
      batches = []
      allow(FactoryBot).to receive(:create_list).and_wrap_original do |original, *args, **kwargs|
        batches << args[1]
        original.call(*args, **kwargs)
      end

      seeder.seed!(10)

      expect(batches).to eq([4, 4, 2])
      expect(Post.count).to eq(10)
    end
  end

  # SKILL.md is explicit: do not auto-generate "unique" values to route around a
  # collision. The `tag` factory in the fixture deliberately has no sequence on a
  # uniquely-indexed column so this path is proven rather than assumed.
  describe "a uniqueness collision" do
    before { config.factory_map = { "tag" => { factory: :tag } } }

    it "does not work around it" do
      seeder.seed!(5)

      expect(Tag.count).to eq(1)
    end

    # A batch that raises part-way through has already committed the rows it managed
    # to create, and create_list returns nothing for them. Those rows are ours, and
    # a tool whose main promise is that it leaves nothing behind must not leave
    # litter in a developer's database because a factory was misconfigured.
    it "adopts the rows the failed batch had already committed, so cleanup removes them" do
      seeder.seed!(5)
      expect(Tag.count).to eq(1)

      seeder.cleanup!

      expect(Tag.count).to eq(0)
      expect(seeder.warnings.join).to include("committed by the batch that failed")
    end

    it "never adopts a row that existed before the run" do
      survivor = Tag.create!(name: "pre-existing")
      seeder.seed!(5)

      seeder.cleanup!

      expect(Tag.pluck(:id)).to eq([survivor.id])
    end

    it "names the factory and the field, with the sequence to add" do
      seeder.seed!(5)

      failure = seeder.failures.first
      expect(failure.factory).to eq(:tag)
      expect(failure.reason).to match(/uniqueness collision/)
      expect(failure.remedy).to include("sequence(:name)")
      expect(failure.remedy).to include("factory :tag do")
    end

    it "says so in the terminal, loudly, with why it will not work around it" do
      seeder.seed!(5)

      expect(stdout.string).to include("SEEDING FAILED for tag")
      expect(stdout.string).to include("will not work around this by generating values itself")
      expect(stdout.string).to include("reported inconclusive rather than healthy")
    end

    it "records how far it got before failing" do
      seeder.seed!(5)

      expect(seeder.failures.first.created).to eq(0)
      expect(seeder.failures.first.requested).to eq(5)
    end

    it "keeps seeding the other resources" do
      config.factory_map = { "tag" => { factory: :tag }, "post" => :post }

      seeder.seed!(3)

      expect(Post.count).to eq(3)
      expect(seeder.failures.map(&:resource)).to eq(["tag"])
    end

    it "seeds fine once the factory has a sequence" do
      config.factory_map = { "unique_tag" => { factory: :unique_tag } }

      seeder.seed!(5)

      expect(Tag.count).to eq(5)
      expect(seeder.failures).to be_empty
    end
  end

  describe "cleanup" do
    before { config.factory_map = { "post" => { factory: :post, trait: :with_comments } } }

    # The rule with no exceptions. A developer's local database holds seed data,
    # fixtures, and hand-crafted state; wiping their tables because they ran a
    # diagnostic tool is unacceptable.
    it "deletes only the rows it created, leaving pre-existing data alone" do
      survivor = FactoryBot.create(:post, title: "I was here first")
      seeder.seed!(5)
      expect(Post.count).to eq(6)

      seeder.cleanup!

      expect(Post.count).to eq(1)
      expect(Post.first.id).to eq(survivor.id)
    end

    # Asserted on the SQL actually executed, so a future well-meaning "faster
    # cleanup" change cannot quietly introduce one.
    it "issues no TRUNCATE, ever" do
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
        statements << ActiveSupport::Notifications::Event.new(*args).payload[:sql]
      end

      seeder.seed!(5)
      seeder.cleanup!

      ActiveSupport::Notifications.unsubscribe(subscriber)
      expect(statements.join("\n")).not_to match(/TRUNCATE|DROP\s+TABLE|DELETE\s+FROM\s+\S+\s*;?\s*\z/i)
      expect(statements.grep(/DELETE FROM/i)).not_to be_empty
    end

    it "deletes children before parents, so a foreign key cannot block it" do
      config.factory_map = { "author" => :author, "post" => { factory: :post, trait: :with_comments } }
      seeder.seed!(3)

      expect { seeder.cleanup! }.not_to raise_error
      expect(Post.count).to eq(0)
    end

    it "is idempotent, so the ensure path and the signal path cannot double-delete" do
      seeder.seed!(3)

      seeder.cleanup!
      expect { seeder.cleanup! }.not_to raise_error
    end

    it "leaves rows in place under :leave, for inspecting the seeded state" do
      config.seed_cleanup_strategy = :leave
      seeder.seed!(4)

      seeder.cleanup!

      expect(Post.count).to eq(4)
      expect(stdout.string).to include("leaving 4 seeded row(s) in place")
    end

    # ensure blocks do not run on signals, and Ctrl-C partway through a 200k-row
    # seed is exactly the state a user will interrupt from.
    it "registers cleanup with Lifecycle, so a signal still removes the rows" do
      seeder.seed!(3)
      expect(lifecycle.registered_names).to include("seeded rows")

      lifecycle.run_teardown!

      expect(Post.count).to eq(0)
    end

    it "does nothing when nothing was seeded" do
      expect { seeder.cleanup! }.not_to raise_error
    end
  end

  describe "the resource guard's say in seeding" do
    it "stops early and records why when the guard asks for less load" do
      config.factory_map = { "post" => :post }
      config.seed_batch_size = 2
      guard = Class.new do
        def initialize = @calls = 0

        def check_seeding_batch!(**)
          @calls += 1
          @calls >= 2 ? :stop : :continue
        end
      end.new
      subject = described_class.new(config: config, lifecycle: lifecycle, guard: guard, stdout: stdout)

      subject.seed!(10)

      expect(Post.count).to eq(4)
      expect(subject.warnings.join).to include("contention guard asked for less load")
    end

    it "carries on without the guard if the guard itself errors" do
      config.factory_map = { "post" => :post }
      guard = Class.new { def check_seeding_batch!(**) = raise("guard is broken") }.new
      subject = described_class.new(config: config, lifecycle: lifecycle, guard: guard, stdout: stdout)

      subject.seed!(3)

      expect(Post.count).to eq(3)
      expect(subject.warnings.join).to include("contention guard errored during seeding")
    end
  end

  describe "#to_h" do
    it "reports what was seeded and every failure, for the report metadata" do
      config.factory_map = { "post" => :post, "tag" => { factory: :tag } }
      seeder.seed!(3)

      audit = seeder.to_h

      expect(audit[:strategy]).to eq(:delete_created_rows)
      expect(audit[:created]).to include("post" => 3)
      # 3 posts, plus the single tag the failed batch had already committed and
      # which the seeder adopted so cleanup can remove it.
      expect(audit[:total_created]).to eq(4)
      expect(audit[:failures].first).to include(resource: "tag")
    end
  end
end

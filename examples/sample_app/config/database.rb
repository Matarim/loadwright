# frozen_string_literal: true

require "active_record"
require "fileutils"

module SampleApp
  # Connection and schema for the fixture app.
  #
  # SQLite on a real FILE, not in-memory. That is not laziness: :http mode boots the
  # app in a SEPARATE PROCESS, and an in-memory database is invisible across
  # processes — so seeded rows would exist for the harness and not for the app under
  # test, and every endpoint would honestly return an empty collection. The
  # resulting run would be a wall of `inconclusive` for a reason that has nothing to
  # do with the app.
  module Database
    module_function

    def path
      ENV["SAMPLE_APP_DATABASE"] ||
        File.expand_path("../db/#{environment}.sqlite3", __dir__)
    end

    def environment = ENV["RAILS_ENV"] || ENV["RACK_ENV"] || "development"

    def connect!
      FileUtils.mkdir_p(File.dirname(path))

      # When booted through config/environment.rb the AR railtie has already
      # connected from config/database.yml. Re-establishing would swap out a working
      # pool for an identical one; the explicit path below is for the non-Rails
      # entry points (a bare `ruby -r.../config/database`).
      return if ActiveRecord::Base.connected?

      ActiveRecord::Base.establish_connection(
        adapter: "sqlite3",
        database: path,
        # The gem drives concurrent requests; the default of 5 is enough to
        # exercise pool pressure without making the fixture the bottleneck.
        pool: Integer(ENV["SAMPLE_APP_POOL"] || 5),
        timeout: 5_000
      )
    end

    def load_schema!
      return if ActiveRecord::Base.connection.table_exists?(:posts)

      ActiveRecord::Schema.verbose = false
      ActiveRecord::Schema.define do
        create_table :authors, force: true do |t|
          t.string :name, null: false
          t.string :slug, null: false
          t.string :email
          t.timestamps
        end
        add_index :authors, :slug, unique: true

        create_table :posts, force: true do |t|
          t.references :author, null: false
          t.string :title, null: false
          t.text :body
          t.boolean :published, null: false, default: true
          t.timestamps
        end
        # NOTE: no index on `published`, deliberately. The seed-scale sweep plus
        # EXPLAIN is supposed to notice the scan as table size grows, and an index
        # here would remove the only cost-growth signal in the fixture. (The
        # author_id index is created automatically by t.references.)

        create_table :comments, force: true do |t|
          t.references :post, null: false
          t.string :author_name
          t.text :body
          t.timestamps
        end

        create_table :tags, force: true do |t|
          t.string :name, null: false
          t.timestamps
        end
        # The unique constraint the `tag` factory deliberately does not satisfy.
        add_index :tags, :name, unique: true

        create_table :post_tags, force: true do |t|
          t.references :post, null: false
          t.references :tag, null: false
        end
      end
    end

    # Used by the gem's own end-to-end specs to start from a known state. NOT used
    # by Loadwright itself, which never truncates anything.
    def reset!
      connect!
      %i[post_tags comments posts authors tags].each do |table|
        ActiveRecord::Base.connection.execute("DELETE FROM #{table}") if
          ActiveRecord::Base.connection.table_exists?(table)
      end
    end
  end
end

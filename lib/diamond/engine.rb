require 'extralite'

module Diamond
  # Engine wraps an Extralite database connection. Schema introspection happens
  # at boot; everything derived from the schema (table proxies, FK caches)
  # lives on the engine instance. Extralite 3.0 enables WAL, foreign_keys and
  # synchronous=NORMAL by default; no PRAGMA setup needed at wake_up.
  class Engine
    attr_reader :db, :schema_cache, :foreign_keys

    def initialize(db_path)
      @db = Extralite::Database.new(db_path)
      @schema_cache = {}
      @foreign_keys = {}

      load_schema!
    end

    def reload_schema!
      # assign fresh mutable hashes, then re-freeze. can't mutate the
      # previously frozen caches in place.
      @schema_cache = {}
      @foreign_keys = {}
      load_schema!
      Diamond.clear_caches!
      freeze!
    end

    # freeze the schema-derived state so the engine is shareable across
    # Ractors. the underlying Extralite database handle remains live; only
    # the cached metadata gets sealed.
    def freeze!
      @schema_cache.freeze
      @foreign_keys.freeze
      @schema_cache.each_value do |schema|
        schema.freeze
        schema[:columns].freeze
        schema[:types].freeze
        schema[:types].each_value(&:freeze)
      end
      @foreign_keys.each_value(&:freeze)
      self
    end

    # refresh one table instead of rescanning everything.
    def load_one_table!(table_name)
      sym = table_name.to_sym
      # build into fresh hashes, then re-freeze.
      new_schema = @schema_cache.merge(sym => parse_table_schema(sym))
      new_fks    = @foreign_keys.merge(sym => parse_foreign_keys(sym))
      @schema_cache = new_schema
      @foreign_keys = new_fks
      freeze!
    end

    private

    def load_schema!
      tables = @db.query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")

      tables.each do |row|
        table_name = row[:name].to_sym
        @schema_cache[table_name] = parse_table_schema(table_name)
        @foreign_keys[table_name] = parse_foreign_keys(table_name)
      end
    end

    def parse_table_schema(table_name)
      columns = []
      types = {}
      primary_key = nil

      @db.query("PRAGMA table_info(#{Diamond.quote_ident(table_name)})").each do |col|
        col_name = col[:name].to_sym
        columns << col_name
        types[col_name] = col[:type]
        primary_key = col_name if col[:pk] == 1
      end

      {
        columns: columns,
        types: types,
        primary_key: primary_key
      }
    end

    def parse_foreign_keys(table_name)
      rows = @db.query("PRAGMA foreign_key_list(#{Diamond.quote_ident(table_name)})")
      rows.map do |row|
        {
          local: row[:from].to_sym,
          ref_table: row[:table].to_sym,
          ref_col: row[:to].to_sym
        }
      end
    end
  end
end

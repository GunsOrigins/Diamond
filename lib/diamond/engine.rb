require 'sqlite3'

module Diamond
  class Engine
    attr_reader :db, :schema_cache, :foreign_keys

    def initialize(db_path)
      @db = SQLite3::Database.new(db_path, results_as_hash: true)
      @schema_cache = {}
      @foreign_keys = {}

      load_schema!
    end

    def reload_schema!
      @schema_cache = {}
      @foreign_keys = {}
      load_schema!
    end

    private

    def load_schema!
      tables = @db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")

      tables.each do |row|
        table_name = row['name'].to_sym
        @schema_cache[table_name] = parse_table_schema(table_name)
        @foreign_keys[table_name] = parse_foreign_keys(table_name)
      end
    end

    def parse_table_schema(table_name)
      columns = []
      types = {}
      primary_key = nil

      @db.execute("PRAGMA table_info(#{Diamond.quote_ident(table_name)})").each do |col|
        col_name = col['name'].to_sym
        columns << col_name
        types[col_name] = col['type']
        primary_key = col_name if col['pk'] == 1
      end

      {
        columns: columns,
        types: types,
        primary_key: primary_key
      }
    end

    def parse_foreign_keys(table_name)
      rows = @db.execute("PRAGMA foreign_key_list(#{Diamond.quote_ident(table_name)})")
      rows.map do |row|
        {
          local: row['from'].to_sym,
          ref_table: row['table'].to_sym,
          ref_col: row['to'].to_sym
        }
      end
    end
  end
end

require 'sqlite3'

module Diamond
  class Engine
    attr_reader :db, :schema_cache

    def initialize(db_path)
      @db = SQLite3::Database.new(db_path, results_as_hash: true)
      @schema_cache = {}
      
      load_schema!
    end

    def reload_schema!
      @schema_cache = {}
      load_schema!
    end

    private

    def load_schema!
      tables = @db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
      
      tables.each do |row|
        table_name = row['name'].to_sym
        @schema_cache[table_name] = parse_table_schema(table_name)
      end
    end

    def parse_table_schema(table_name)
      columns = []
      types = {}
      primary_key = nil

      @db.execute("PRAGMA table_info(#{table_name})").each do |col|
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
  end
end
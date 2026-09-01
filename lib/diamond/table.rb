require_relative 'ast'
require_relative 'schema_proxy'
require_relative 'query_object'
require_relative 'parser'

require_relative 'dsl/default'

module Diamond
  class Table
    include Diamond::DSL::Default

    attr_reader :name, :schema

    def initialize(name)
      @name = name
      @schema = Diamond.engine.schema_cache[name]
    end

    def find(id)
      pk = @schema[:primary_key] || :id
      condition = AST::Equality.new(AST::Column.new(pk), AST::Literal.new(id))
      QueryObject.new(self, [AST::Where.new(condition)])
    end

    def create(data_hash)
      sql, params = Compiler.compile_insert(self, data_hash)
      
      # Execute the INSERT
      Diamond.engine.db.execute(sql, params)
      
      # Fetch the new ID and materialize the struct to ensure DB defaults/triggers are applied
      new_id = Diamond.engine.db.last_insert_row_id
      find(new_id).first
    end

    # Start a query from a CTE alias instead of the physical table
    def from_cte(alias_name)
      QueryObject.new(self, [AST::From.new(alias_name)])
    end
  end
end
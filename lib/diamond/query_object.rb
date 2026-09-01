require_relative 'compiler'
require_relative 'struct_factory'
require_relative 'schema_proxy'
require_relative 'parser'

require_relative 'dsl/default'

module Diamond
  class InertObjectError < StandardError; end
  class UnknownColumnError < StandardError; end

  class QueryObject
    include Diamond::DSL::Default

    attr_reader :table, :ast

    def initialize(table, ast = [])
      @table = table
      @ast = ast
      @cached_result = nil
    end

    def materialize
      return @cached_result if @cached_result

      sql, params = Diamond::Compiler.compile(@table, @ast)
      
      # 1. Prepare the statement (C-level)
      stmt = Diamond.engine.db.prepare(sql)
      
      # 2. Bind parameters safely
      stmt.bind_params(params)
      
      # 3. Execute to get the ResultSet cursor
      result_set = stmt.execute
      
      # 4. Determine projection
      projection_node = @ast.find { |n| n.is_a?(AST::Projection) }
      projected_columns = projection_node&.columns

      # 5. Stream rows lazily. 
      # We build the array, but we don't duplicate the data into a Hash first.
      @cached_result = []
      result_set.each do |row_hash|
        @cached_result << Diamond::StructFactory.create(@table, row_hash, projected_columns)
      end
      
      # 6. Close the statement to free C-level memory immediately
      stmt.close 
      
      @cached_result
    end

    def first
      materialize.first
    end

    # Immediate execution. Returns the integer number of rows affected.
    def update(data_hash)
      # Invalidate cache if we previously materialized this query
      @cached_result = nil 
      
      sql, params = Compiler.compile_update(@table, @ast, data_hash)
      Diamond.engine.db.execute(sql, params)
      Diamond.engine.db.changes
    end

    # Immediate execution. Returns the integer number of rows deleted.
    def delete
      @cached_result = nil
      
      sql, params = Compiler.compile_delete(@table, @ast)
      Diamond.engine.db.execute(sql, params)
      Diamond.engine.db.changes
    end

    def method_missing(name, *args, &block)
      if @table.schema[:columns].include?(name)
        record = materialize.first
        raise Diamond::RecordNotFound, "No record found for AST: #{@ast.inspect}" if record.nil?
        record.public_send(name, *args, &block)
      else
        super
      end
    end

    def inspect
      if @cached_result
        "#<Diamond::QueryObject materialized: #{@cached_result.size} records>"
      else
        "#<Diamond::QueryObject table=#{@table.name} ast=#{@ast.map(&:class).map(&:name).join(', ')}>"
      end
    end
  end
end
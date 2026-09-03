require_relative 'struct_factory'
require_relative 'compiler/base'

module Diamond
  class QueryObject
    attr_reader :table, :ast

    def initialize(table, ast = [])
      @table = table
      @ast = ast
      @cached_result = nil
    end

    def materialize
      return @cached_result if @cached_result

      sql, params = Diamond::Compiler::Base.compile(@table, @ast)

      stmt = Diamond.engine.db.prepare(sql)
      stmt.bind_params(params)
      result_set = stmt.execute

      projection_node = @ast.find { |n| n.is_a?(AST::Projection) }
      projected_columns = projection_node&.columns

      @cached_result = []
      result_set.each do |row_hash|
        @cached_result << Diamond::StructFactory.create(@table, row_hash, projected_columns)
      end
      stmt.close

      @cached_result
    end

    # n == 1 returns a single Struct; n > 1 returns an Array of Structs.
    # Auto-injects ORDER BY id ASC only when no Order node exists.
    def first(n = 1)
      scope = has_order? ? self : order(:id)
      results = scope.limit(n).materialize
      n == 1 ? results.first : results
    end

    # n == 1 returns a single Struct; n > 1 returns an Array of Structs in
    # ascending id order (we query DESC then reverse in Ruby).
    # Auto-injects ORDER BY id DESC only when no Order node exists.
    def last(n = 1)
      scope = has_order? ? self : order([:id, :desc])
      results = scope.limit(n).materialize
      n == 1 ? results.first : results.reverse
    end

    # 1 column → flat array of values; n columns → array of arrays.
    # Strips any existing Projection from the chain (terminals don't
    # conflict with prior derives).
    def pluck(*columns)
      raise ArgumentError, "pluck requires at least one column" if columns.empty?
      columns.each do |c|
        raise Diamond::UnknownColumnError.build(@table.schema, c) unless @table.schema[:columns].include?(c)
      end
      new_nodes = columns.map { |c| AST::Column.new(c) }
      filtered = @ast.reject { |n| n.is_a?(AST::Projection) } + [AST::Projection.new(new_nodes)]
      rows = Diamond::QueryObject.new(@table, filtered).materialize
      if columns.size == 1
        rows.map { |s| s.public_send(columns.first) }
      else
        rows.map { |s| columns.map { |c| s.public_send(c) } }
      end
    end

    # SELECT <pk> LIMIT 1; cheap existence check.
    def exists?
      pk  = @table.schema[:primary_key] || :id
      col = AST::Column.new(pk)
      filtered = @ast.reject { |n| n.is_a?(AST::Projection) } + [AST::Projection.new([col])]
      Diamond::QueryObject.new(@table, filtered).limit(1).materialize.any?
    end

    # Equivalent to derive { count(primary_key) }, executed and unwrapped
    # to an Integer. Strips any prior Projection.
    def count
      pk    = @table.schema[:primary_key] || :id
      nodes = [AST::Function.new(:count, [AST::Column.new(pk)])]
      filtered = @ast.reject { |n| n.is_a?(AST::Projection) } + [AST::Projection.new(nodes)]
      Diamond::QueryObject.new(@table, filtered).materialize.first.count_id
    end

    def method_missing(name, *args, &block)
      if @table.schema[:columns].include?(name)
        record = first
        raise Diamond::RecordNotFound, "No record found for AST: #{@ast.inspect}" if record.nil?
        record.public_send(name, *args, &block)
      else
        super
      end
    end

    def respond_to_missing?(name, include_private = false)
      @table.schema[:columns].include?(name) || super
    end

    def inspect
      if @cached_result
        "#<Diamond::QueryObject materialized: #{@cached_result.size} records>"
      else
        "#<Diamond::QueryObject table=#{@table.name} ast=[#{@ast.map(&:class).map(&:name).join(', ')}]>"
      end
    end

    private

    def has_order?
      @ast.any? { |n| n.is_a?(AST::Order) }
    end
  end
end

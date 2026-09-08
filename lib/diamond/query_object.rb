require_relative 'struct_factory'
require_relative 'compiler/base'
require_relative 'cursor'

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
      begin
        stmt.bind_params(params)
        result_set = stmt.execute

        projection_node = @ast.find { |n| n.is_a?(AST::Projection) }
        projected_columns = projection_node&.columns

        @cached_result = []
        result_set.each do |row_hash|
          @cached_result << Diamond::StructFactory.create(@table, row_hash, projected_columns)
        end
      ensure
        begin
          stmt.close unless stmt.closed?
        rescue StandardError
          # ensure must not raise - close is idempotent via the closed? check
        end
      end

      @cached_result
    end

    def first(n = 1)
      scope = has_order? ? self : order(default_order_column!)
      results = scope.limit(n).materialize
      n == 1 ? results.first : results
    end

    def each(&block)
      compiled_sql, compiled_params = Diamond::Compiler::Base.compile(@table, @ast)
      stmt = Diamond.engine.db.prepare(compiled_sql)
      stmt.bind_params(compiled_params)

      projection_node   = @ast.find { |n| n.is_a?(AST::Projection) }
      projected_columns = projection_node&.columns

      cursor = Diamond::Cursor.new(@table, stmt, projected_columns)

      if block
        cursor.each(&block)
      else
        cursor
      end
    end

    def last(n = 1)
      scope = has_order? ? self : order([default_order_column!, :desc])
      results = scope.limit(n).materialize
      n == 1 ? results.first : results.reverse
    end

    # skip the structs entirely - read values straight off the cursor.
    def pluck(*columns)
      raise ArgumentError, "pluck requires at least one column" if columns.empty?
      columns.each do |c|
        raise Diamond::UnknownColumnError.build(@table.schema, c) unless @table.schema[:columns].include?(c)
      end
      new_nodes = columns.map { |c| AST::Column.new(c) }
      filtered = @ast.reject { |n| n.is_a?(AST::Projection) } + [AST::Projection.new(new_nodes)]
      q = Diamond::QueryObject.new(@table, filtered)
      sql, params = Diamond::Compiler::Base.compile(q.table, q.ast)
      stmt = Diamond.engine.db.prepare(sql)
      begin
        stmt.bind_params(params)
        keys = columns.map(&:to_s)
        if columns.size == 1
          key = keys.first
          result = []
          stmt.execute.each { |row| result << row[key] }
          result
        else
          result = []
          stmt.execute.each { |row| result << keys.map { |k| row[k] } }
          result
        end
      ensure
        begin
          stmt.close unless stmt.closed?
        rescue StandardError
          # ensure must not raise
        end
      end
    end

    def exists?
      pk  = resolve_pk!
      col = AST::Column.new(pk)
      filtered = @ast.reject { |n| n.is_a?(AST::Projection) } + [AST::Projection.new([col])]
      q = Diamond::QueryObject.new(@table, filtered).limit(1)
      sql, params = Diamond::Compiler::Base.compile(q.table, q.ast)
      stmt = Diamond.engine.db.prepare(sql)
      begin
        stmt.bind_params(params)
        found = false
        stmt.execute.each { |_row| found = true; break }
        found
      ensure
        begin
          stmt.close unless stmt.closed?
        rescue StandardError
          # ensure must not raise
        end
      end
    end

    def count
      pk    = resolve_pk!
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

    # pk or :id, and it better exist. fail here with a column error
    # instead of letting sqlite complain about COUNT(missing).
    def resolve_pk!
      pk = @table.schema[:primary_key] || :id
      unless @table.schema[:columns].include?(pk)
        raise Diamond::UnknownColumnError.build(@table.schema, pk)
      end
      pk
    end

    # same deal for the implicit ORDER BY id in first/last.
    def default_order_column!
      col = :id
      unless @table.schema[:columns].include?(col)
        raise Diamond::UnknownColumnError.build(@table.schema, col)
      end
      col
    end
  end
end

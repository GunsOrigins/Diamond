module Diamond
  class SchemaProxy < BasicObject
    AGGREGATIONS = [:count, :sum, :avg, :min, :max]
    WINDOW_FUNCS = [:row_number, :rank, :dense_rank, :lag, :lead]

    def initialize(schema)
      @schema = schema
    end

    # Catch barewords (column names)
    def method_missing(name, *args, &block)
      if @schema[:columns].empty? || @schema[:columns].include?(name)
        AST::Column.new(name)
      elsif AGGREGATIONS.include?(name)
        arg_nodes = args.map { |a| a.is_a?(AST::Column) ? a : AST::Column.new(a) }
        AST::Function.new(name, arg_nodes)
      elsif WINDOW_FUNCS.include?(name)
        WindowBuilder.new(name,args)
      else
        ::Kernel.raise ::Diamond::UnknownColumnError.build(@schema, name)
      end
    end
  end

  class WindowBuilder
      def initialize(func_name, args)
        @func_name = func_name
        @args = args.map { |a| AST::Column.new(a) }
      end

      def over(partition_by: nil, order: nil)
        AST::WindowFunction.new(
          @func_name,
          @args,
          partition_by: Array(partition_by),
          order_by: Array(order)
        )
      end
  end
end
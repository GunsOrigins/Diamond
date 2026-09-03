module Diamond
  module DSL
    module Default
      def where(&block)
        _build_where(&block)
      end

      def find(id)
        pk = _schema_for_dsl[:primary_key] || :id
        condition = Diamond::AST::Equality.new(
          Diamond::AST::Column.new(pk),
          Diamond::AST::Literal.new(id)
        )
        _build_where_node(condition)
      end

      def derive(*args, &block)
        _build_projection(*args, &block)
      end

      def join(table_name, on: nil, type: :inner)
        _build_join(table_name, type, on)
      end

      def define_relation(name, &block)
        ast = _build_relation(name, &block)
        sql, params = Diamond::Compiler::DDL.compile(ast)
        Diamond.engine.db.execute(sql, *params)
        Diamond.engine.reload_schema!
        ast
      end

      def create(**kwargs)
        _build_create(kwargs)
      end

      def update(&block)
        result = _build_update(&block)
        @cached_result = nil if defined?(@cached_result) && @cached_result
        result
      end

      def delete
        result = _build_delete
        @cached_result = nil if defined?(@cached_result) && @cached_result
        result
      end

      def from_cte(alias_name)
        Diamond::QueryObject.new(self, [Diamond::AST::From.new(alias_name)])
      end

      # --- Honey Batch: chaining + terminals ---

      def order(*args, **kwargs)
        _build_order(*args, **kwargs)
      end

      def limit(n)
        _build_limit(n)
      end

      def offset(n)
        _build_offset(n)
      end

      # Terminals delegate to QueryObject. When called on a Table, wrap
      # it in a fresh QueryObject first.
      def pluck(*columns)
        _wrap.pluck(*columns)
      end

      def exists?
        _wrap.exists?
      end

      def count
        _wrap.count
      end

      def first(n = 1)
        _wrap.first(n)
      end

      def last(n = 1)
        _wrap.last(n)
      end

      private

      def _wrap
        is_a?(Diamond::Table) ? Diamond::QueryObject.new(self) : self
      end
    end
  end
end

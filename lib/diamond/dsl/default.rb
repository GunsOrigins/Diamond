module Diamond
  module DSL
    module Default
      def where(&block)
        _build_where(&block)
      end

      # chain `.or { condition }` to OR the last where clause with the new one
      # `Users.where { name == 'Arle' }.or { age > 10 }` => `WHERE name = ? OR age > ?`
      def or(&block)
        _build_or_where(&block)
      end

      def find(id)
        pk = _schema_for_dsl[:primary_key] || :id
        condition = Diamond::AST::Equality.new(
          Diamond::AST::Column.new(pk),
          Diamond::AST::Literal.new(id)
        )
        _build_where_node(condition)
      end

      # `where_in(:col, query)` creates a WHERE col IN (SELECT ...) condition.
      # `Users.where_in(:id, Posts.derive(:user_id))` compiles to
      # `SELECT * FROM users WHERE id IN (SELECT user_id FROM posts)`.
      def where_in(column, subquery)
        col_node = AST::Column.new(column)
        sub_node = AST::Subquery.new(subquery)
        condition = AST::In.new(col_node, sub_node)
        _build_where_node(condition)
      end

      # alias kept for back-compat
      alias_method :where_sub, :where_in

      # Build a projection. Accepts column symbols, AST nodes, or a block
      # that yields bare columns, function calls, and window chains. Also
      # used to shape a subquery for `where_in`:
      #   Users.where_in(:id, Posts.derive(:user_id))
      def derive(*args, &block)
        _build_projection(*args, &block)
      end

      def join(table_name, on: nil, type: :inner, eager: false)
        _build_join(table_name, type, on, eager: eager)
      end

      # `.includes(:posts, :comments)` eager-loads child relations.
      # sugar for `.join(:posts, eager: true).join(:comments, eager: true)`.
      def includes(*tables)
        _build_includes(*tables)
      end

      def define_relation(name, &block)
        ast = _build_relation(name, &block)
        sql, params = Diamond::Compiler::DDL.compile(ast)
        Diamond.engine.db.execute(sql, *params)

        # indexes go after the table exists. needs PRAGMA foreign_keys=ON
        # for cascades (wake_up turns it on).
        ast.columns.select { |c| c.is_a?(Diamond::AST::IndexDefinition) }.each do |idx|
          idx_sql, idx_params = Diamond::Compiler::DDL.compile_index(idx, name)
          Diamond.engine.db.execute(idx_sql, *idx_params)
        end

        Diamond.engine.load_one_table!(name)

        # bind a frozen top-level constant immediately. without this, a
        # worker Ractor would have to fall through `const_missing`, which
        # calls `Object.const_set` and is illegal from non-main Ractors.
        const_name = name.to_s.split('_').map(&:capitalize).join
        unless Object.const_defined?(const_name, false)
          proxy = Diamond::Table.new(name).freeze
          Object.const_set(const_name, proxy)
          Diamond.note_bound_table(const_name)
        end

        ast
      end

      def create_index(table_name, columns, unique: false, name:)
        raise ArgumentError, "create_index requires `name:` kwarg" unless name
        raise ArgumentError, "create_index requires at least one column" if Array(columns).empty?
        idx = Diamond::AST::IndexDefinition.new(name, columns, unique: !!unique)
        sql, params = Diamond::Compiler::DDL.compile_index(idx, table_name)
        Diamond.engine.db.execute(sql, *params)
        Diamond.engine.load_one_table!(table_name)
        idx
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

      # --- Chaining + terminals ---

      def order(*args, **kwargs)
        _build_order(*args, **kwargs)
      end

      def limit(n)
        _build_limit(n)
      end

      def offset(n)
        _build_offset(n)
      end

      def group(*columns)
        _build_group(columns)
      end

      def having(&block)
        _build_having(&block)
      end

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

      def each(&block)
        _wrap.each(&block)
      end

      private

      def _wrap
        is_a?(Diamond::Table) ? Diamond::QueryObject.new(self) : self
      end
    end
  end
end

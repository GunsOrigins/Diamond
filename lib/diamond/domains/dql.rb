module Diamond
  module Domains
    module DQL
      # how each chainable node reconciles with the nodes already on the
      # chain. builders validate args and construct nodes; _chain applies
      # the strategy. new AST node types declare one line here (unknown
      # classes accumulate).
      RECONCILE = {
        AST::Where      => :accumulate,
        AST::Join       => :accumulate,
        AST::With       => :accumulate,
        AST::Order      => :merge,
        AST::Limit      => :replace,
        AST::Offset     => :replace,
        AST::GroupBy    => :replace,
        AST::Having     => :replace,
        AST::Projection => :once
      }.freeze

      # the one operation every chain call funnels through. wraps a bare
      # Table into a QueryObject, then reconciles the node into the ast.
      # `.or` passes strategy: :fold_or explicitly — the single escape
      # hatch, since folding rewrites history instead of appending.
      def _chain(node, strategy: nil)
        strategy ||= RECONCILE.fetch(node.class, :accumulate)
        table = self.is_a?(Diamond::Table) ? self : @table
        base  = self.is_a?(Diamond::Table) ? [] : @ast
        Diamond::QueryObject.new(table, DQL.apply_strategy(strategy, base, node))
      end

      def self.apply_strategy(strategy, ast, node)
        case strategy
        when :accumulate
          ast + [node]
        when :replace
          ast.reject { |n| n.instance_of?(node.class) } + [node]
        when :merge # Order: concat specs into a single node
          existing = ast.find { |n| n.is_a?(AST::Order) }
          merged = AST::Order.new((existing ? existing.specs : []) + node.specs)
          ast.reject { |n| n.is_a?(AST::Order) } + [merged]
        when :once # Projection: second one is a usage error
          raise "derive() called twice; use it once on each chain" if ast.any? { |n| n.is_a?(AST::Projection) }

          ast + [node]
        when :fold_or # .or: merge into the last Where, else append fresh
          idx = ast.rindex { |n| n.is_a?(AST::Where) }
          if idx
            combined = AST::Or.new(ast[idx].condition, node.condition)
            duped = ast.dup
            duped[idx] = AST::Where.new(combined)
            duped
          else
            ast + [node]
          end
        end
      end

      def _build_where(&block)
        condition = Parser.parse_block(block, _schema_for_dsl, _scope_for_dsl)
        raise "Where block must return an AST condition" unless condition.is_a?(AST::Node)
        _chain(AST::Where.new(condition))
      end

      def _build_or_where(&block)
        condition = Parser.parse_block(block, _schema_for_dsl, _scope_for_dsl)
        raise "Or block must return an AST condition" unless condition.is_a?(AST::Node)
        _chain(AST::Where.new(condition), strategy: :fold_or)
      end

      def _build_where_node(condition_node)
        raise "Where node must be an AST::Node" unless condition_node.is_a?(AST::Node)
        _chain(AST::Where.new(condition_node))
      end

      def _build_projection(*args, &block)
        nodes = if args.empty? && block_given?
                  Parser.parse_derive(block, _schema_for_dsl)
                else
                  args.map do |a|
                    if a.is_a?(Symbol)
                      unless _schema_for_dsl[:columns].include?(a)
                        raise Diamond::UnknownColumnError.build(_schema_for_dsl, a)
                      end
                      AST::Column.new(a)
                    else
                      a
                    end
                  end
                end
        _chain(AST::Projection.new(nodes))
      end

      def _build_join(table_name, type, on, eager: false)
        if on.nil?
          on = _resolve_join_keys(table_name)
        end
        _chain(AST::Join.new(table_name, type, on, eager: eager))
      end

      # `.includes(:posts)` is sugar for `.join(:posts, eager: true)`.
      # supports a single table or a list. each eagerly-loaded child becomes
      # a nested struct array on the parent.
      def _build_includes(*tables)
        result = self
        tables.each do |table_name|
          result = result._build_join(table_name, :left, nil, eager: true)
        end
        result
      end

      def _build_order(*args, **kwargs)
        pairs = []
        args.each do |a|
          sym, dir =
            if a.is_a?(Array) && a.size == 2 && a[1].is_a?(Symbol)
              [a[0].to_sym, a[1]]
            else
              [a.to_sym, :asc]
            end
          raise Diamond::UnknownColumnError.build(_schema_for_dsl, sym) unless _schema_for_dsl[:columns].include?(sym)
          unless %i[asc desc].include?(dir)
            raise ArgumentError, "direction must be :asc or :desc, got #{dir.inspect}"
          end
          pairs << [sym, dir]
        end
        kwargs.each do |col, direction|
          sym = col.to_sym
          raise Diamond::UnknownColumnError.build(_schema_for_dsl, sym) unless _schema_for_dsl[:columns].include?(sym)
          d = direction.to_s.downcase.to_sym
          unless %i[asc desc].include?(d)
            raise ArgumentError, "direction must be :asc or :desc, got #{direction.inspect}"
          end
          pairs << [sym, d]
        end
        raise ArgumentError, "order requires at least one column" if pairs.empty?

        _chain(AST::Order.new(pairs))
      end

      def _build_limit(n)
        raise ArgumentError, "limit must be Integer >= 0, got #{n.inspect}" unless n.is_a?(Integer) && n >= 0
        _chain(AST::Limit.new(n))
      end

      def _build_offset(n)
        raise ArgumentError, "offset must be Integer >= 0, got #{n.inspect}" unless n.is_a?(Integer) && n >= 0
        _chain(AST::Offset.new(n))
      end

      def _build_group(columns)
        validated = columns.map do |c|
          sym = c.to_sym
          raise Diamond::UnknownColumnError.build(_schema_for_dsl, sym) unless _schema_for_dsl[:columns].include?(sym)
          sym
        end
        _chain(AST::GroupBy.new(validated))
      end

      def _build_having(&block)
        condition = Parser.parse_block(block, _schema_for_dsl, _scope_for_dsl)
        raise "Having block must return an AST condition" unless condition.is_a?(AST::Node)
        _chain(AST::Having.new(condition))
      end

      # --- Context Hooks (Used by the DSL modules) ---
      def _schema_for_dsl
        self.is_a?(Diamond::Table) ? @schema : @table.schema
      end

      # tables the current chain can filter on: the base table plus every
      # joined table, each mapped to its schema. lets `tags.tag` in a
      # block resolve to a qualified column. unknown join targets are
      # skipped (their own errors surface at compile time).
      def _scope_for_dsl
        base = self.is_a?(Diamond::Table) ? @name : @table.name
        scope = { base => _schema_for_dsl }
        joins = self.is_a?(Diamond::Table) ? [] : @ast.select { |n| n.is_a?(AST::Join) }
        joins.each do |j|
          sch = Diamond.engine.schema_cache[j.table_name]
          scope[j.table_name] = sch if sch
        end
        scope
      end

      private

      def _resolve_join_keys(target_table)
        current = _current_table_name
        fks = Diamond.engine.foreign_keys

        if fks[current]
          fks[current].each do |fk|
            return { fk[:local] => fk[:ref_col] } if fk[:ref_table] == target_table
          end
        end

        if fks[target_table]
          fks[target_table].each do |fk|
            return { fk[:local] => fk[:ref_col] } if fk[:ref_table] == current
          end
        end

        raise Diamond::TableNotFound,
              "No foreign key connects '#{current}' and '#{target_table}'. " \
              "Pass `on: { <local>: <ref> }` explicitly."
      end

      def _current_table_name
        self.is_a?(Diamond::Table) ? @name : @table.name
      end
    end
  end
end

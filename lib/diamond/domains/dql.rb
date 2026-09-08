module Diamond
  module Domains
    module DQL
      def _build_where(&block)
        condition = Parser.parse_block(block, _schema_for_dsl)
        raise "Where block must return an AST condition" unless condition.is_a?(AST::Node)
        _append_to_query([AST::Where.new(condition)])
      end

      def _build_where_node(condition_node)
        raise "Where node must be an AST::Node" unless condition_node.is_a?(AST::Node)
        _append_to_query([AST::Where.new(condition_node)])
      end

      def _build_projection(*args, &block)
        raise "derive() called twice; use it once on each chain" if self.is_a?(Diamond::QueryObject) && @ast.any? { |n| n.is_a?(AST::Projection) }

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
        _append_to_query([AST::Projection.new(nodes)])
      end

      def _build_join(table_name, type, on)
        if on.nil?
          on = _resolve_join_keys(table_name)
        end
        _append_to_query([AST::Join.new(table_name, type, on)])
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

        # chained .order calls merge into one Order node, one ORDER BY out.
        if self.is_a?(Diamond::QueryObject) && (existing = @ast.find { |n| n.is_a?(AST::Order) })
          combined = AST::Order.new(existing.specs + pairs)
          Diamond::QueryObject.new(@table, @ast.reject { |n| n.is_a?(AST::Order) } + [combined])
        elsif self.is_a?(Diamond::Table)
          Diamond::QueryObject.new(self, [AST::Order.new(pairs)])
        else
          Diamond::QueryObject.new(@table, @ast + [AST::Order.new(pairs)])
        end
      end

      def _build_limit(n)
        raise ArgumentError, "limit must be Integer >= 0, got #{n.inspect}" unless n.is_a?(Integer) && n >= 0
        _filter_or_append(AST::Limit, AST::Limit.new(n))
      end

      def _build_offset(n)
        raise ArgumentError, "offset must be Integer >= 0, got #{n.inspect}" unless n.is_a?(Integer) && n >= 0
        _filter_or_append(AST::Offset, AST::Offset.new(n))
      end

      # --- Context Hooks (Used by the DSL modules) ---
      def _schema_for_dsl
        self.is_a?(Diamond::Table) ? @schema : @table.schema
      end

      def _append_to_query(nodes)
        if self.is_a?(Diamond::Table)
          Diamond::QueryObject.new(self, nodes)
        else
          Diamond::QueryObject.new(@table, @ast + nodes)
        end
      end

      private

      # last call wins.
      def _filter_or_append(node_class, new_node)
        if self.is_a?(Diamond::Table)
          Diamond::QueryObject.new(self, [new_node])
        else
          Diamond::QueryObject.new(@table, @ast.reject { |n| n.is_a?(node_class) } + [new_node])
        end
      end

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

module Diamond
  module Compiler
    module DQL
      JOIN_TYPE_MAP = {
        inner: 'INNER JOIN',
        left:  'LEFT OUTER JOIN',
        right: 'RIGHT OUTER JOIN',
        full:  'FULL OUTER JOIN'
      }.freeze

      def self.compile(table, ast, params = [])
        with_clauses = ast.select { |n| n.is_a?(AST::With) }
        projection   = ast.find { |n| n.is_a?(AST::Projection) }
        joins        = ast.select { |n| n.is_a?(AST::Join) }
        wheres       = ast.select { |n| n.is_a?(AST::Where) }
        from_node    = ast.find { |n| n.is_a?(AST::From) }

        with_sql    = render_with(with_clauses, params)
        select_sql  = render_projection(projection, params)
        from_target = from_node ? from_node.name : table.name
        Diamond.validate_ident!(from_target, "FROM target")
        from_sql    = "FROM #{from_target}"
        joins_sql   = joins.map { |j| render_join(j, from_target) }.join(' ')
        where_sql   = wheres.empty? ? '' : ' WHERE ' + wheres.map { |w| translate_node(w.condition, params) }.join(' AND ')

        # Combine all Order specs across every Order node (if multiple exist).
        # Last Order in source order wins for tie-breaking semantics; concat is
        # the documented behavior.
        order_specs = ast.select { |n| n.is_a?(AST::Order) }.flat_map(&:specs)
        order_sql   = order_specs.empty? ? '' : ' ORDER BY ' + order_specs.map { |col, dir| "#{col} #{dir.to_s.upcase}" }.join(', ')

        # Multiple Limit / Offset nodes: last-wins.
        limit_node  = ast.reverse.find { |n| n.is_a?(AST::Limit) }
        limit_sql   = limit_node ? ' LIMIT ?' : ''
        params << limit_node.value if limit_node

        offset_node = ast.reverse.find { |n| n.is_a?(AST::Offset) }
        offset_sql  = offset_node ? ' OFFSET ?' : ''
        params << offset_node.value if offset_node

        sql = "#{with_sql} SELECT #{select_sql} #{from_sql}#{joins_sql.empty? ? '' : ' ' + joins_sql}#{where_sql}#{order_sql}#{limit_sql}#{offset_sql}"
        sql = sql.strip
        [sql, params]
      end

      def self.render_with(with_nodes, params)
        return '' if with_nodes.empty?
        pieces = with_nodes.map { |w| render_single_with(w, params) }
        'WITH ' + pieces.join(', ')
      end

      def self.render_single_with(node, params)
        rec = node.recursive ? 'RECURSIVE ' : ''
        sub_sql = render_with_query(node.query, params)
        "#{rec}#{node.name} AS (#{sub_sql})"
      end

      def self.render_with_query(query, params)
        if query.is_a?(AST::Union)
          left_sql  = render_with_query(query.left, params)
          right_sql = render_with_query(query.right, params)
          "#{left_sql} #{query.operator} #{right_sql}"
        else
          # QueryObject
          sub_sql, _ = Diamond::Compiler::Base.compile(query.table, query.ast, params)
          sub_sql
        end
      end

      def self.render_projection(node, params)
        return '*' if node.nil?
        node.columns.map { |c| translate_node(c, params) }.join(', ')
      end

      def self.render_join(node, current_table)
        Diamond.validate_ident!(node.table_name, "join table")
        sql_type = JOIN_TYPE_MAP[node.type] || raise(ArgumentError, "Unknown join type: #{node.type}")
        on_clauses = node.on.map do |local, ref|
          "#{node.table_name}.#{local} = #{current_table}.#{ref}"
        end
        "#{sql_type} #{node.table_name} ON #{on_clauses.join(' AND ')}"
      end

      def self.translate_node(node, params)
        case node
        when Symbol
          node.to_s
        when AST::Column
          node.name.to_s
        when AST::Literal
          params << node.value
          '?'
        when AST::Function
          args_str = node.args.map { |a| translate_node(a, params) }.join(', ')
          "#{node.name}(#{args_str})"
        when AST::WindowFunction
          args_str = node.args.map { |a| translate_node(a, params) }.join(', ')
          func_str = "#{node.func_name}(#{args_str})"
          parts = []
          parts << "PARTITION BY #{node.partition_by.join(', ')}" unless node.partition_by.empty?
          parts << "ORDER BY #{node.order_by.join(', ')}" unless node.order_by.empty?
          if parts.empty?
            func_str
          else
            "#{func_str} OVER (#{parts.join(' ')})"
          end
        when AST::BinaryOp
          left  = translate_node(node.left, params)
          right = translate_node(node.right, params)
          if [:AND, :OR].include?(node.operator)
            "(#{left} #{node.operator} #{right})"
          else
            "#{left} #{node.operator} #{right}"
          end
        when AST::In, AST::NotIn
          # Empty array → tautologically false (IN) or true (NOT IN).
          # SQL disallows `IN ()` / `NOT IN ()` so we substitute a constant
          # predicate that always evaluates to the right polarity.
          if node.right.empty?
            return node.is_a?(AST::NotIn) ? '1=1' : '1=0'
          end
          # Emit each element via translate_node — handles Literals (pushes
          # value to params, emits `?`) AND expression elements (Column refs,
          # BinaryOps, etc. emit their SQL form with no `?` placeholder).
          element_sqls = node.right.map { |r| translate_node(r, params) }
          kw = node.is_a?(AST::NotIn) ? 'NOT IN' : 'IN'
          "#{translate_node(node.left, [])} #{kw} (#{element_sqls.join(', ')})"
        else
          raise "Unknown AST Node: #{node.class}"
        end
      end
    end
  end
end

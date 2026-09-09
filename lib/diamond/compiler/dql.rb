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
        # one loop over ast instead of ~8 selects. bucket everything, render after.
        with_clauses = []
        projection   = nil
        joins        = []
        wheres       = []
        from_node    = nil
        order_specs  = []
        limit_node   = nil
        offset_node  = nil
        group_by_node = nil
        having_node  = nil
        ast.each do |n|
          case n
          when AST::With       then with_clauses << n
          when AST::Projection then projection ||= n
          when AST::Join       then joins << n
          when AST::Where      then wheres << n
          when AST::From       then from_node ||= n
          when AST::Order      then order_specs.concat(n.specs)
          when AST::Limit      then limit_node = n
          when AST::Offset     then offset_node = n
          when AST::GroupBy    then group_by_node = n
          when AST::Having     then having_node = n
          end
        end

        from_target = from_node ? from_node.name : table.name
        Diamond.validate_ident!(from_target, "FROM target")

        # if any join is eager, we need aliased columns + a transform spec
        # so the result rows can be deduplicated and nested.
        has_eager = joins.any?(&:eager)
        if has_eager
          return compile_eager(table, from_target, projection, joins, wheres, order_specs,
                               with_clauses, limit_node, offset_node,
                               group_by_node, having_node, params)
        end

        with_sql    = render_with(with_clauses, params)
        select_sql  = render_projection(projection, params)
        from_sql    = "FROM #{from_target}"
        joins_sql   = joins.map { |j| render_join(j, from_target) }.join(' ')
        where_sql   = wheres.empty? ? '' : ' WHERE ' + wheres.map { |w| translate_node(w.condition, params) }.join(' AND ')
        group_sql   = group_by_node ? " GROUP BY #{group_by_node.columns.join(', ')}" : ''
        having_sql  = having_node ? ' HAVING ' + translate_node(having_node.condition, params) : ''

        # specs already merged up top. one ORDER BY out.
        order_sql   = order_specs.empty? ? '' : ' ORDER BY ' + order_specs.map { |col, dir| "#{col} #{dir.to_s.upcase}" }.join(', ')

        # last Limit/Offset node wins. values go in raw, not bound -
        # _build_limit/_build_offset already checked Integer >= 0, and
        # old sqlite builds choke on (or misplan) bound LIMIT ?.
        limit_sql   = limit_node ? " LIMIT #{limit_node.value}" : ''

        offset_sql  = offset_node ? " OFFSET #{offset_node.value}" : ''

        sql = "#{with_sql} SELECT #{select_sql} #{from_sql}#{joins_sql.empty? ? '' : ' ' + joins_sql}#{where_sql}#{group_sql}#{having_sql}#{order_sql}#{limit_sql}#{offset_sql}"
        sql = sql.strip
        [sql, params, nil]
      end

      # eager-loading path: build a SELECT with aliased columns (table.col AS
      # "table.col") so the Extralite::Transform can disambiguate which table
      # a column belongs to, then return the transform spec alongside SQL.
      def self.compile_eager(table, from_target, projection, joins, wheres, order_specs, with_clauses, limit_node, offset_node, group_by_node, having_node, params)
        # 1. column list: parent cols (with optional projection) + aliased
        #    columns from each eager join
        parent_cols = if projection
                        projection.columns.map { |c| member_column(c) }.compact
                      else
                        table.schema[:columns]
                      end

        select_parts = []
        # parent: bare column names. Extralite returns them as keys like
        # "id", "name", etc. The transform spec keys must match these.
        parent_cols.each do |col|
          select_parts << "#{from_target}.#{col}"
        end
        # children: alias each column as "table.col" so the transform can
        # tell parent columns from child columns with the same name (e.g.
        # both tables have an "id" column).
        joins.each do |j|
          next unless j.eager
          child_table = j.table_name
          child_schema = Diamond.engine.schema_cache[child_table]
          child_schema[:columns].each do |col|
            select_parts << "#{child_table}.#{col} AS \"#{child_table}.#{col}\""
          end
        end
        select_sql = select_parts.join(', ')

        # 2. JOIN clauses. eager joins get rewritten to LEFT OUTER JOIN so
        #    parents without children still appear.
        render_join_eager = ->(j) {
          sql_type = (j.eager ? 'LEFT OUTER JOIN' : JOIN_TYPE_MAP[j.type])
          Diamond.validate_ident!(j.table_name, "join table")
          on_clauses = j.on.map do |local, ref|
            "#{j.table_name}.#{local} = #{from_target}.#{ref}"
          end
          "#{sql_type} #{j.table_name} ON #{on_clauses.join(' AND ')}"
        }
        joins_sql = joins.map { |j| render_join_eager.call(j) }.join(' ')

        # 3. WHERE, GROUP BY, HAVING, ORDER BY, LIMIT, OFFSET. when the query
        #    is eager, qualify bare column names in WHERE/HAVING with the
        #    parent table name so they don't collide with child table columns.
        where_sql = if wheres.empty?
                      ''
                    else
                      prefix = "#{from_target}."
                      ' WHERE ' + wheres.map { |w| translate_where_qualified(w.condition, params, prefix) }.join(' AND ')
                    end
        group_sql = group_by_node ? " GROUP BY #{group_by_node.columns.map { |c| "#{from_target}.#{c}" }.join(', ')}" : ''
        having_sql = having_node ? ' HAVING ' + translate_where_qualified(having_node.condition, params, "#{from_target}.") : ''
        order_sql  = order_specs.empty? ? '' : ' ORDER BY ' + order_specs.map { |col, dir| "#{from_target}.#{col} #{dir.to_s.upcase}" }.join(', ')
        limit_sql  = limit_node ? " LIMIT #{limit_node.value}" : ''
        offset_sql = offset_node ? " OFFSET #{offset_node.value}" : ''

        with_sql = render_with(with_clauses, params)
        sql = "#{with_sql} SELECT #{select_sql} FROM #{from_target}#{joins_sql.empty? ? '' : ' ' + joins_sql}#{where_sql}#{group_sql}#{having_sql}#{order_sql}#{limit_sql}#{offset_sql}".strip

        # 4. build the transform spec
        transform = build_transform(from_target, table, parent_cols, joins)

        [sql, params, transform]
      end

      # AST column -> underlying column name (only Column nodes; ignore
      # Function/WindowFunction in eager mode for now).
      def self.member_column(node)
        case node
        when AST::Column then node.name
        end
      end

      def self.build_transform(from_target, table, parent_cols, joins)
        # build a hash describing the expected row layout. The Extralite
        # transform expects the spec wrapped in { columns: { ... } } and
        # uses each spec key as the lookup key against the result set's
        # column name. We alias child columns as "table.col" so the
        # transform can disambiguate when parent and child share column
        # names like "id".
        eager_joins = joins.select(&:eager)
        columns_spec = {}

        parent_cols.each do |col|
          type = type_for_column(from_target, col)
          columns_spec[col.to_s] = { type: type }
        end

        eager_joins.each do |j|
          child_table = j.table_name
          child_schema = Diamond.engine.schema_cache[child_table]
          child_columns = {}
          child_schema[:columns].each do |col|
            type = type_for_column(child_table, col)
            child_columns["#{child_table}.#{col}"] = { type: type }
          end
          # mark primary key for dedup
          pk = child_schema[:primary_key]
          child_columns["#{child_table}.#{pk}"][:identity] = true if pk

          columns_spec[child_table.to_s] = [{
            type: :relation,
            columns: child_columns
          }]
        end

        # parent primary key for dedup at the parent level
        pk = table.schema[:primary_key]
        columns_spec[pk.to_s][:identity] = true if pk

        { columns: columns_spec }
      end

      def self.type_for_column(table, column)
        # map sqlite type strings (INTEGER, TEXT, REAL) to extralite
        # transform types. default to text for unknown types.
        type_str = Diamond.engine.schema_cache[table][:types][column]
        case type_str
        when 'INTEGER' then :integer
        when 'REAL'    then :float
        else :text
        end
      end

      # Kept for the eager path; now a thin wrapper around translate_node
      # with the parent-table prefix so unqualified Column references don't
      # collide with child-table columns.
      def self.translate_where_qualified(node, params, prefix)
        translate_node(node, params, prefix: prefix)
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

      def self.translate_node(node, params, prefix: '')
        hook = Operators.call(node, params)
        return hook if hook
        case node
        when Symbol
          node.to_s
        when AST::Column
          # already qualified (`tags.tag`) wins over the eager prefix.
          node.table ? "#{node.table}.#{node.name}" : "#{prefix}#{node.name}"
        when AST::Literal
          params << node.value
          '?'
        when AST::Subquery
          sub_sql, _ = Diamond::Compiler::Base.compile(node.query.table, node.query.ast, params)
          "(#{sub_sql})"
        when AST::IsNull
          "#{translate_node(node.column, params, prefix: prefix)} IS NULL"
        when AST::IsNotNull
          "#{translate_node(node.column, params, prefix: prefix)} IS NOT NULL"
        when AST::Between
          col_sql = translate_node(node.column, params, prefix: prefix)
          low_sql = translate_node(node.low, params, prefix: prefix)
          high_sql = translate_node(node.high, params, prefix: prefix)
          "#{col_sql} BETWEEN #{low_sql} AND #{high_sql}"
        when AST::Function
          args_str = node.args.map { |a| translate_node(a, params, prefix: prefix) }.join(', ')
          "#{node.name}(#{args_str})"
        when AST::WindowFunction
          args_str = node.args.map { |a| translate_node(a, params, prefix: prefix) }.join(', ')
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
          left  = translate_node(node.left, params, prefix: prefix)
          right = translate_node(node.right, params, prefix: prefix)
          if [:AND, :OR].include?(node.operator)
            "(#{left} #{node.operator} #{right})"
          else
            "#{left} #{node.operator} #{right}"
          end
        when AST::In, AST::NotIn
          # subquery form: `col IN (SELECT ...)`
          if node.right.is_a?(AST::Subquery)
            left_sql  = translate_node(node.left, params, prefix: prefix)
            right_sql = translate_node(node.right, params, prefix: prefix)
            kw = node.is_a?(AST::NotIn) ? 'NOT IN' : 'IN'
            return "#{left_sql} #{kw} #{right_sql}"
          end
          # no `IN ()` in sql, so empty means `1=0`, empty NOT IN means `1=1`.
          if node.right.empty?
            return node.is_a?(AST::NotIn) ? '1=1' : '1=0'
          end
          # Elements may be expressions, not just Literals. no `?` then.
          element_sqls = node.right.map { |r| translate_node(r, params, prefix: prefix) }
          kw = node.is_a?(AST::NotIn) ? 'NOT IN' : 'IN'
          left_sql = translate_node(node.left, [], prefix: prefix)
          # sqlite caps bound vars per statement, so slice big lists into
          # 500s. IN groups get OR, NOT IN groups get AND (de morgan).
          groups = element_sqls.each_slice(500).map { |g| "#{left_sql} #{kw} (#{g.join(', ')})" }
          return groups.first if groups.size == 1
          joiner = node.is_a?(AST::NotIn) ? ' AND ' : ' OR '
          "(#{groups.join(joiner)})"
        else
          raise "Unknown AST Node: #{node.class}"
        end
      end
    end
  end
end

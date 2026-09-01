module Diamond
  module Compiler
    def self.compile(table, ast)
      params = []
      # Handle CTEs (WITH clause)
      ctes = ast.select { |n| n.is_a?(AST::With) }
      with_clause = ""
      unless ctes.empty?
        cte_strings = ctes.map do |cte|
          # Pass the main params array so CTE params get collected!
          sub_sql = compile_union_or_query(cte.query, params)
          rec = cte.recursive ? "RECURSIVE " : ""
          "#{rec}#{cte.name} AS (#{sub_sql})"
        end
        with_clause = "WITH " + cte_strings.join(", ")
      end

      # Determine FROM clause
      from_node = ast.find { |n| n.is_a?(AST::From) }
      from_target = from_node ? from_node.name : table.name

      # Determine SELECT clause
      projection = ast.find { |n| n.is_a?(AST::Projection) }
      if projection
        select_clause = projection.columns.map { |c| translate_node(c, params) }.join(", ")
      else
        select_clause = "*"
      end

      sql = "#{with_clause} SELECT #{select_clause} FROM #{from_target}".strip

      # Determine WHERE clause
      wheres = ast.select { |node| node.is_a?(AST::Where) }
      unless wheres.empty?
        conditions = wheres.map do |where_node|
          translate_node(where_node.condition, params)
        end
        sql += " WHERE " + conditions.join(" AND ")
      end
      
      [sql, params]
    end

    def self.compile_union_or_query(union_or_query, params = [])
      if union_or_query.is_a?(AST::Union)
        left_sql = compile_union_or_query(union_or_query.left, params)
        right_sql = compile_union_or_query(union_or_query.right, params)
        "#{left_sql} #{union_or_query.operator} #{right_sql}"
      else
        # It's a QueryObject! Compile it directly and COLLECT THE PARAMS!
        sql, sub_params = compile(union_or_query.table, union_or_query.ast)
        params.concat(sub_params)
        sql
      end
    end

    def self.translate_node(node, params)
      case node
      when Symbol
        node.to_s
      when AST::Column
        node.name.to_s
      when AST::Literal
        params << node.value
        "?"
      when AST::Function
        args_str = node.args.map { |a| translate_node(a, params) }.join(", ")
        "#{node.name}(#{args_str})"
      when AST::WindowFunction
        args_str = node.args.map { |a| translate_node(a, params) }.join(", ")
        func_str = "#{node.func_name}(#{args_str})"
        
        if node.partition_by.any? || node.order_by.any?
          parts = []
          parts << "PARTITION BY #{node.partition_by.join(', ')}" if node.partition_by.any?
          parts << "ORDER BY #{node.order_by.join(', ')}" if node.order_by.any?
          func_str + " OVER (#{parts.join(' ')})"
        else
          func_str
        end
      when AST::BinaryOp
        left = translate_node(node.left, params)
        right = translate_node(node.right, params)
        
        if [:AND, :OR].include?(node.operator)
          "(#{left} #{node.operator} #{right})"
        else
          "#{left} #{node.operator} #{right}"
        end
      else
        raise "Unknown AST Node: #{node.class}"
      end
    end

    def self.compile_insert(table, data_hash)
      columns = data_hash.keys
      values = data_hash.values
      
      cols_str = columns.join(", ")
      vals_str = (["?"] * columns.size).join(", ")
      
      sql = "INSERT INTO #{table.name} (#{cols_str}) VALUES (#{vals_str})"
      [sql, values]
    end

    def self.compile_update(table, ast, data_hash)
      set_clause = data_hash.keys.map { |k| "#{k} = ?" }.join(", ")
      set_params = data_hash.values
      
      sql = "UPDATE #{table.name} SET #{set_clause}"
      where_params = []
      
      wheres = ast.select { |node| node.is_a?(AST::Where) }
      unless wheres.empty?
        conditions = wheres.map do |where_node|
          translate_node(where_node.condition, where_params)
        end
        sql += " WHERE " + conditions.join(" AND ")
      end
      
      [sql, set_params + where_params]
    end

    def self.compile_delete(table, ast)
      sql = "DELETE FROM #{table.name}"
      params = []
      
      wheres = ast.select { |node| node.is_a?(AST::Where) }
      unless wheres.empty?
        conditions = wheres.map do |where_node|
          translate_node(where_node.condition, params)
        end
        sql += " WHERE " + conditions.join(" AND ")
      end
      
      [sql, params]
    end
  end
end
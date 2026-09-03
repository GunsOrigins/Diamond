module Diamond
  module Compiler
    module DDL
      TYPE_MAP = {
        Integer    => 'INTEGER',
        String     => 'TEXT',
        Float      => 'REAL',
        TrueClass  => 'INTEGER',
        FalseClass => 'INTEGER'
      }.freeze

      def self.compile(node)
        raise ArgumentError, "Expected AST::DefineRelation, got #{node.class}" unless node.is_a?(AST::DefineRelation)

        column_clauses = node.columns.select { |c| c.is_a?(AST::ColumnDefinition) }.map { |c| render_column(c) }
        fk_clauses    = node.columns.select { |c| c.is_a?(AST::ForeignKey) }.map { |c| render_foreign_key(c) }

        body = (column_clauses + fk_clauses).join(', ')
        sql  = "CREATE TABLE #{node.name} (#{body})"
        [sql, []]
      end

      def self.render_column(node)
        sql_type = TYPE_MAP[node.type] or raise ArgumentError, "Unsupported column type: #{node.type}"
        parts    = [node.name.to_s, sql_type]

        if node.options[:primary_key]
          parts << 'PRIMARY KEY'
        elsif node.options[:nullable] == false
          parts << 'NOT NULL'
        end

        parts.join(' ')
      end

      def self.render_foreign_key(node)
        "FOREIGN KEY (#{node.local_column}) REFERENCES #{node.ref_table}(#{node.ref_column})"
      end
    end
  end
end

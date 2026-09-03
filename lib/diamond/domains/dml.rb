module Diamond
  module Domains
    module DML
      def _build_create(hash)
        ast = AST::Insert.new(hash)
        new_id = Diamond::Compiler::DML.compile_insert(_current_table, ast)
        _current_table.find(new_id).first
      end

      def _build_update(&block)
        raise ArgumentError, "update requires a block" unless block_given?
        hash = Diamond::Parser.parse_update(block, _schema_for_dsl)
        wheres = _where_nodes
        Diamond::Compiler::DML.compile_update(_current_table, hash, wheres)
      end

      def _build_delete
        wheres = _where_nodes
        Diamond::Compiler::DML.compile_delete(_current_table, wheres)
      end

      private

      def _current_table
        is_a?(Diamond::Table) ? self : @table
      end

      def _where_nodes
        return [] unless self.is_a?(Diamond::QueryObject)
        @ast.select { |n| n.is_a?(AST::Where) }
      end
    end
  end
end

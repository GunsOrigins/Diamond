module Diamond
  module Domains
    module DDL
      def _build_relation(name, &block)
        raise ArgumentError, "define_relation requires a block" unless block
        columns = Diamond::Parser.parse_ddl(block)
        AST::DefineRelation.new(name, columns)
      end
    end
  end
end

module Diamond
  module Domains
    module CTE
      def with(cte_hash, &block)
        raise ArgumentError, "Diamond.with requires a block" unless block_given?

        cte_nodes = cte_hash.map { |alias_name, query| AST::With.new(alias_name, query) }

        proxy = Object.new
        proxy.define_singleton_method(:from) do |alias_name|
          QueryObject.new(NullTable.new(alias_name), [AST::From.new(alias_name)])
        end

        main_query = yield(proxy)
        QueryObject.new(main_query.table, cte_nodes + main_query.ast)
      end

      def with_recursive(name, base_query, recursive_query)
        union_node = AST::Union.new(base_query, recursive_query)
        dummy_table = NullTable.new(name)
        QueryObject.new(dummy_table, [AST::With.new(name, union_node, recursive: true)])
      end
    end
  end
end

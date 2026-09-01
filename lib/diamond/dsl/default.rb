module Diamond
  module DSL
    module Default
      # We define this as a module method that takes the context (self)
      # so it can be included in both Table and QueryObject.
      
      def where(&block)
        condition = Diamond::Parser.parse_block(block, _schema_for_dsl)
        raise "Where block must return an AST condition" unless condition.is_a?(Diamond::AST::Node)
        
        _build_query([Diamond::AST::Where.new(condition)])
      end

      def derive(*args, &block)
        if block_given?
          proxy = Diamond::SchemaProxy.new(_schema_for_dsl)
          node = proxy.instance_eval(&block)
          raise "Derive block must return an AST node" unless node.is_a?(Diamond::AST::Node)
          args = [node]
        end
        
        _build_query([Diamond::AST::Projection.new(args)])
      end

      # --- Hooks for the including classes ---

      # Returns the schema to validate against
      def _schema_for_dsl
        if self.is_a?(Diamond::Table)
          @schema
        else
          @table.schema
        end
      end

      # Returns a new QueryObject with the appended AST
      def _build_query(nodes)
        if self.is_a?(Diamond::Table)
          Diamond::QueryObject.new(self, nodes)
        else
          Diamond::QueryObject.new(@table, @ast + nodes)
        end
      end
    end
  end
end
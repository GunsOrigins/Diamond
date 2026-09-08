module Diamond
  module Parser
    # Registry consulted at the front of translate_where. External operators
    # run first, sorted by descending priority. First non-nil result wins.
    # Built-ins are implicit priority 0 (they fall through).
    module WhereOperators
      @handlers = []

      def self.register(operator)
        @handlers << operator unless @handlers.include?(operator)
        nil
      end

      def self.handlers
        @handlers
      end

      def self.clear!
        @handlers = []
      end

      def self.call(node, schema)
        @handlers.sort_by { |h| -h.priority }.each do |h|
          result = h.parse_where(node, schema)
          return result if result
        end
        nil
      end
    end

    # Registry consulted at the front of translate_derive.
    module DeriveOperators
      @handlers = []

      def self.register(operator)
        @handlers << operator unless @handlers.include?(operator)
        nil
      end

      def self.handlers
        @handlers
      end

      def self.clear!
        @handlers = []
      end

      def self.call(node, schema)
        @handlers.sort_by { |h| -h.priority }.each do |h|
          result = h.parse_derive(node, schema)
          return result if result
        end
        nil
      end
    end
  end
end

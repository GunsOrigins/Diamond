module Diamond
  module Compiler
    # Registry consulted at the front of DQL.translate_node. Operators declare
    # which AST nodes they handle via .handles?, then render to SQL fragments.
    # The render method is expected to mutate the params array (matches the
    # convention used by the built-in case statement).
    module Operators
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

      def self.call(node, params)
        @handlers.sort_by { |h| -h.priority }.each do |h|
          if h.handles?(node)
            return h.render(node, params)
          end
        end
        nil
      end
    end
  end
end

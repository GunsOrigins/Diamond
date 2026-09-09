module Diamond
  module Compiler
    # Registry consulted at the front of DQL.translate_node. Operators declare
    # which AST nodes they handle via .handles?, then render to SQL fragments.
    # The render method is expected to mutate the params array (matches the
    # convention used by the built-in case statement).
    #
    # Per-Ractor: each Ractor owns its own handler list, stored on the
    # Ractor's local storage. The module holds only the frozen list of
    # built-ins (which is shareable).
    module Operators
      STORAGE_KEY = :_diamond_compiler_ops

      def self.builtins
        [Diamond::Operators::Like].freeze
      end

      def self.handlers
        Ractor.current[STORAGE_KEY] ||= builtins.dup
      end

      def self.register(operator)
        list = handlers
        list << operator unless list.include?(operator)
        nil
      end

      def self.clear!
        Ractor.current[STORAGE_KEY] = builtins.dup
      end

      def self.call(node, params)
        handlers.sort_by { |h| -h.priority }.each do |h|
          if h.handles?(node)
            return h.render(node, params)
          end
        end
        nil
      end
    end
  end
end

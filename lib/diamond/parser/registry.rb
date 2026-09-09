module Diamond
  module Parser
    # Registry consulted at the front of translate_where. External operators
    # run first, sorted by descending priority. First non-nil result wins.
    # Built-ins are implicit priority 0 (they fall through).
    #
    # Per-Ractor: each Ractor owns its own handler list, stored on the
    # Ractor's own local storage. The module holds only the frozen list of
    # built-ins (which is shareable).
    module WhereOperators
      STORAGE_KEY = Diamond::RACTOR_KEYS[:where_ops]

      # method, not a constant: this file loads before the Like operator
      # is defined, so it must resolve lazily. called once per Ractor
      # (handlers memoizes), so the per-call allocation is irrelevant.
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

      def self.call(node, schema)
        handlers.sort_by { |h| -h.priority }.each do |h|
          result = h.parse_where(node, schema)
          return result if result
        end
        nil
      end
    end

    # Registry consulted at the front of translate_derive.
    module DeriveOperators
      STORAGE_KEY = Diamond::RACTOR_KEYS[:derive_ops]

      def self.builtins
        [].freeze  # no built-in derive operators yet
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

      def self.call(node, schema)
        handlers.sort_by { |h| -h.priority }.each do |h|
          result = h.parse_derive(node, schema)
          return result if result
        end
        nil
      end
    end
  end
end

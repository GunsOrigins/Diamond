module Diamond
  module Domains
    module DynamicFinders
      FINDER_PREFIX = 'by_'.freeze
      AND_SEPARATOR = '_and_'.freeze

      def method_missing(name, *args, &block)
        method_str = name.to_s
        return super unless method_str.start_with?(FINDER_PREFIX)

        column_strs = method_str.delete_prefix(FINDER_PREFIX).split(AND_SEPARATOR)
        if column_strs.empty?
          raise ArgumentError, "Invalid dynamic finder '#{name}': no columns after prefix"
        end

        columns = column_strs.map(&:to_sym)
        unless args.size == columns.size
          raise ArgumentError,
                "wrong number of arguments for #{name} (given #{args.size}, expected #{columns.size})"
        end

        columns.each do |col|
          unless _schema_for_dsl[:columns].include?(col)
            raise Diamond::UnknownColumnError.build(_schema_for_dsl, col)
          end
        end

        pairs = columns.zip(args)
        condition = pairs.drop(1).reduce(build_equality(pairs.first)) do |acc, pair|
          AST::And.new(acc, build_equality(pair))
        end

        _append_to_query([AST::Where.new(condition)])
      end

      def respond_to_missing?(name, include_private = false)
        name.to_s.start_with?(FINDER_PREFIX) || super
      end

      private

      def build_equality(pair)
        col, val = pair
        AST::Equality.new(AST::Column.new(col), AST::Literal.new(val))
      end
    end
  end
end

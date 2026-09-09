require_relative 'dql'
require_relative 'dml'

module Diamond
  module Compiler
    module Base
      # Returns [sql, params, transform_or_nil]. The transform is non-nil
      # only for eager-loaded queries; non-eager callers can ignore it.
      def self.compile(table, ast, params = nil)
        params ||= []
        DQL.compile(table, ast, params)
      end
    end
  end
end

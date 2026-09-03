require_relative 'dql'
require_relative 'dml'

module Diamond
  module Compiler
    module Base
      def self.compile(table, ast, params = nil)
        params ||= []
        DQL.compile(table, ast, params)
      end
    end
  end
end

require_relative 'ast'
require_relative 'query_object'

module Diamond
  class Table
    attr_reader :name, :schema

    def initialize(name)
      @name = name
      @schema = Diamond.engine.schema_cache[name]
    end
  end
end

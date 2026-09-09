require_relative 'ast'
require_relative 'query_object'

module Diamond
  class Table
    attr_reader :name, :schema

    def initialize(name)
      @name = name
      @schema = Diamond.engine.schema_cache[name]
    end

    # column names in DDL order.
    def columns
      @schema[:columns]
    end

    # primary key column, or nil.
    def primary_key
      @schema[:primary_key]
    end
  end
end

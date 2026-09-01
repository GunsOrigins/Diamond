module Diamond
  class NullTable
    attr_reader :name, :schema

    def initialize(name = nil)
      @name = name
      @schema = { columns: [], types: {}, primary_key: nil }
    end
  end
end
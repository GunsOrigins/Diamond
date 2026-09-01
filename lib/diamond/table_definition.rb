module Diamond
  class TableDefinition
    def initialize(name)
      @name = name
      @columns = []
    end

    def primary_key(name = :id)
      @columns << "#{name} INTEGER PRIMARY KEY"
    end

    def text(name)
      @columns << "#{name} TEXT"
    end

    def integer(name)
      @columns << "#{name} INTEGER"
    end

    def real(name)
      @columns << "#{name} REAL"
    end

    def blob(name)
      @columns << "#{name} BLOB"
    end

    def to_sql
      cols = @columns.join(", ")
      "CREATE TABLE #{@name} (#{cols})"
    end
  end
end
require_relative 'diamond/engine'
require_relative 'diamond/table'
require_relative 'diamond/query_object'
require_relative 'diamond/null_table'
require_relative 'diamond/table_definition'

module Diamond
  class TableNotFound < StandardError; end
  class RecordNotFound < StandardError; end
  class InertObjectError < StandardError; end
  
  class UnknownColumnError < StandardError
    def self.build(schema, name)
      cols = schema[:columns].map(&:to_s)

      spell_checker = DidYouMean::SpellChecker.new(dictionary: cols)
      suggestions = spell_checker.correct(name.to_s)
      
      message = "Table has no column '#{name}'."
      message += " Did you mean '#{suggestions.first}'?" unless suggestions.empty?
      
      new(message)
    end
  end

  @engine = nil

  def self.wake_up(db_path)
    @engine = Engine.new(db_path)
  end

  def self.engine
    @engine
  end

  # CTE Macro: Diamond.with(alias: query) { Diamond.from(alias) }
  def self.with(cte_hash)
    raise "CTE requires a block" unless block_given?

    cte_nodes = cte_hash.map do |alias_name, query_obj|
      AST::With.new(alias_name, query_obj)
    end

    # Yield a dummy object to build the main query
    proxy = Object.new
    proxy.define_singleton_method(:from) do |alias_name|
      # We use a dummy table reference; the compiler will override it
      QueryObject.new(Diamond::NullTable.new(name: alias_name, schema: { columns: [], types: {}, primary_key: nil }), [AST::From.new(alias_name)])
    end
    
    main_query = yield(proxy)
    
    # Prepend the WITH nodes to the main query's AST
    QueryObject.new(main_query.table, cte_nodes + main_query.ast)
  end

  # Recursive CTE Macro
  def self.with_recursive(name, base_query, recursive_query)
    # Pass the QueryObjects directly!
    union_node = AST::Union.new(base_query, recursive_query)
    
    dummy_table = Diamond::NullTable.new(name)
    
    QueryObject.new(dummy_table, [AST::With.new(name, union_node, recursive: true)])
  end

  def self.create_table(name, &block)
    definition = TableDefinition.new(name)
    definition.instance_eval(&block)
    
    engine.db.execute(definition.to_sql)
    
    engine.reload_schema!
  end
end

class Module
  def const_missing(name)
    table_sym = name.to_s.downcase.to_sym
    
    if Diamond.engine&.schema_cache&.key?(table_sym)
      proxy = Diamond::Table.new(table_sym)
      const_set(name, proxy)
      proxy
    else
      raise NameError, "uninitialized constant #{name}"
    end
  end
end
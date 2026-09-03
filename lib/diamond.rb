require 'sqlite3'
require 'prism'
require 'did_you_mean'

# Suppress the "finalizer references object to be finalized" warning that
# the Ruby VM emits whenever Cursor's GC finalizer proc is registered. The
# finalizer uses ObjectSpace._id2ref to avoid actually closing over the
# Cursor or its Statement, but Ruby's parser still flags the registration
# conservatively. The Cursor has its own ensure + GC finalizer chain;
# documentation covers the leak-prevention model.
Warning.singleton_class.prepend(Module.new do
  def warn(msg, category: nil)
    return if msg.is_a?(String) && msg.include?('finalizer references object to be finalized')
    super
  end
end)

require_relative 'diamond/version'
require_relative 'diamond/engine'
require_relative 'diamond/ast'
require_relative 'diamond/parser'
require_relative 'diamond/null_table'
require_relative 'diamond/struct_factory'
require_relative 'diamond/table'
require_relative 'diamond/query_object'
require_relative 'diamond/compiler/base'
require_relative 'diamond/compiler/dql'
require_relative 'diamond/compiler/ddl'
require_relative 'diamond/compiler/dml'
require_relative 'diamond/domains/dql'
require_relative 'diamond/domains/ddl'
require_relative 'diamond/domains/dml'
require_relative 'diamond/domains/cte'
require_relative 'diamond/domains/dynamic_finders'
require_relative 'diamond/dsl/default'

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
    # Enable FK action clauses (CASCADE / SET NULL / etc.) at the SQLite
    # connection level. The pragma is per-connection; this also runs for
    # `:memory:` databases where the default is OFF.
    @engine.db.execute('PRAGMA foreign_keys = ON')

    Diamond::Table.include(Diamond::DSL::Default)
    Diamond::Table.include(Diamond::Domains::DQL)
    Diamond::Table.include(Diamond::Domains::DML)
    Diamond::Table.include(Diamond::Domains::DynamicFinders)

    Diamond::QueryObject.include(Diamond::DSL::Default)
    Diamond::QueryObject.include(Diamond::Domains::DQL)
    Diamond::QueryObject.include(Diamond::Domains::DML)
    Diamond::QueryObject.include(Diamond::Domains::DynamicFinders)

    Diamond.extend(Diamond::Domains::DDL)
    Diamond.extend(Diamond::Domains::CTE)
    Diamond.extend(Diamond::DSL::Default)
  end

  def self.engine
    @engine
  end
end

# Install the const_missing hook via Module.prepend so we don't trigger
# the static "method redefined" warning that reopening Module with `def`
# would emit. Prepend inserts the module into the ancestor chain without
# replacing the original const_missing.
module DiamondConstMissing
  def const_missing(name)
    table_sym = name.to_s.downcase.to_sym

    if Diamond.engine && Diamond.engine.schema_cache.key?(table_sym)
      proxy = Diamond::Table.new(table_sym)
      const_set(name, proxy)
      proxy
    else
      super
    end
  end
end
Module.prepend(DiamondConstMissing)

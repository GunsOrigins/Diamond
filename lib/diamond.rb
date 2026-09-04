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

  IDENT_RE = /\A[a-zA-Z_][a-zA-Z0-9_]*\z/.freeze

  # Double-quote an identifier for interpolation into SQL (PRAGMA paths
  # read table names back out of sqlite_master, which is DB-controlled
  # content — never interpolate it raw).
  def self.quote_ident(name)
    "\"#{name.to_s.gsub('"', '""')}\""
  end

  # Reject identifiers that would need quoting anywhere else. Called at
  # DDL/compile boundaries so emitted SQL stays unquoted (and all existing
  # SQL-string assertions keep passing) while malicious names fail fast
  # with a clear error instead of injecting.
  def self.validate_ident!(name, what = "identifier")
    unless name.to_s.match?(IDENT_RE)
      raise ArgumentError, "invalid #{what} #{name.inspect}: must match #{IDENT_RE.inspect}"
    end
    name
  end

  # Tables bound via const_missing (e.g. `Users`) are tracked here so a
  # later wake_up against a different database can rebind them instead of
  # leaving them pinned to the previous engine's schema.
  @bound_tables = []

  def self.wake_up(db_path)
    @engine = Engine.new(db_path)
    # Enable FK action clauses (CASCADE / SET NULL / etc.) at the SQLite
    # connection level. The pragma is per-connection; this also runs for
    # `:memory:` databases where the default is OFF.
    @engine.db.execute('PRAGMA foreign_keys = ON')

    # Idempotent: including an already-included module is a no-op for the
    # ancestor chain, but each call still busts Ruby's global method cache.
    # Guard so repeated wake_up (e.g. per-test setup) doesn't pay that.
    unless Diamond::Table.include?(Diamond::DSL::Default)
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

    rebind_tables!
  end

  # Re-resolve previously bound table constants against the new engine's
  # schema. Constants for tables missing in the new schema are removed so
  # the next reference raises NameError (via const_missing) instead of
  # silently serving the old engine's Table.
  def self.rebind_tables!
    @bound_tables.each do |const_name|
      Object.send(:remove_const, const_name) if Object.const_defined?(const_name, false)
    end
    @bound_tables.clear
  end

  def self.note_bound_table(const_name)
    @bound_tables << const_name unless @bound_tables.include?(const_name)
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
      # Bind table proxies globally (::Users), not in the lexical scope
      # (e.g. DiamondTest::Users when referenced inside a test). Table
      # proxies are engine-global by design, and rebind_tables! tracks and
      # removes ::Name constants on re-wake.
      Object.const_set(name, proxy)
      Diamond.note_bound_table(name)
      proxy
    else
      super
    end
  end
end
Module.prepend(DiamondConstMissing)

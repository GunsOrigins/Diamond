# shareable_constant_value: literal
#
# makes every top-level constant declared below shareable across Ractors.
# `Users` etc. become references to shareable objects, so a Ractor can
# resolve `Users` without going through any global mutable state.

require 'extralite'
require 'prism'
require 'did_you_mean'

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

  # Central registry of keys used to stash per-Ractor state in
  # `Ractor.current[...]`. One place so the namespace stays grep-able and
  # collisions are impossible. Each consumer module has a constant pointing
  # here: `Diamond::RACTOR_KEYS[:engine]`, etc.
  RACTOR_KEYS = {
    engine:           :_diamond_engine,
    parser_caches:    :_diamond_parser_caches,
    struct_caches:    :_diamond_struct_caches,
    where_ops:        :_diamond_where_ops,
    derive_ops:       :_diamond_derive_ops,
    compiler_ops:     :_diamond_compiler_ops,
    finder_cols:      :_diamond_finder_cols
  }.freeze

  @db_path = nil

  IDENT_RE = /\A[a-zA-Z_][a-zA-Z0-9_]*\z/.freeze
end

require_relative 'diamond/version'
require_relative 'diamond/operator'
require_relative 'diamond/engine'
require_relative 'diamond/ast'
require_relative 'diamond/parser/registry'
require_relative 'diamond/parser'
require_relative 'diamond/null_table'
require_relative 'diamond/struct_factory'
require_relative 'diamond/table'
require_relative 'diamond/query_object'
require_relative 'diamond/compiler/registry'
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
require_relative 'diamond/operators/like'

module Diamond
  def self.quote_ident(name)
    "\"#{name.to_s.gsub('"', '""')}\""
  end

  def self.validate_ident!(name, what = "identifier")
    unless name.to_s.match?(IDENT_RE)
      raise ArgumentError, "invalid #{what} #{name.inspect}: must match #{IDENT_RE.inspect}"
    end
    name
  end

  # Names we've bound as frozen constants, so a later wake_up can unbind them
  # instead of leaving them pinned to the dead engine's schema.
  @bound_tables = []

  def self.wake_up(db_path)
    @db_path = db_path.freeze

    # Main Ractor initializes its connection immediately for backward compat
    # (so existing tests that touch `Diamond.engine` after wake_up still work).
    Ractor.current[Diamond::RACTOR_KEYS[:engine]] = Engine.new(@db_path).freeze!

    # including twice is a no-op for ancestors but still busts ruby's global
    # method cache. guard it so per-test wake_up stays cheap.
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
    bind_tables!
  end

  # drop old constants so the next reference re-resolves (or raises
  # NameError) instead of serving the dead engine's table.
  def self.rebind_tables!
    @bound_tables.each do |const_name|
      Object.send(:remove_const, const_name) if Object.const_defined?(const_name, false)
    end
    @bound_tables.clear
  end

  # eager-bind every schema table as a frozen top-level constant. Ractor-safe
  # because the Table object is immutable after .freeze, and the engine's
  # schema cache is frozen (see Engine#freeze!).
  def self.bind_tables!
    return unless Ractor.current[Diamond::RACTOR_KEYS[:engine]]
    Ractor.current[Diamond::RACTOR_KEYS[:engine]].schema_cache.each_key do |table_sym|
      const_name = table_sym.to_s.split('_').map(&:capitalize).join
      next if Object.const_defined?(const_name, false)
      proxy = Table.new(table_sym).freeze
      Object.const_set(const_name, proxy)
      @bound_tables << const_name unless @bound_tables.include?(const_name)
    end
  end

  def self.note_bound_table(const_name)
    @bound_tables << const_name unless @bound_tables.include?(const_name)
  end

  # Per-Ractor engine. Each Ractor opens its own Extralite::Database connection
  # lazily on first access. The shared schema/FK caches are loaded from the
  # same DB file/connection-string, so every Ractor sees the same logical
  # schema — but live query execution goes through each Ractor's own connection.
  def self.engine
    Ractor.current[Diamond::RACTOR_KEYS[:engine]] ||= Engine.new(@db_path).freeze!
  end

  # Wrap a block in BEGIN/COMMIT. Rolls back on exception.
  #
  #   Diamond.transaction do
  #     Users.create(name: 'A')
  #     Posts.create(title: 'B', user_id: 1)
  #   end
  #
  # Returns the block's return value on commit, re-raises on rollback.
  def self.transaction(&block)
    raise ArgumentError, "transaction requires a block" unless block
    db = engine.db
    db.execute('BEGIN')
    begin
      result = block.call
      db.execute('COMMIT')
      result
    rescue StandardError
      db.execute('ROLLBACK')
      raise
    end
  end

  # drop everything derived from the old schema. runs on reload_schema!.
  # per-Ractor: clears only the calling Ractor's parser/struct/finder
  # caches. operator registries are untouched (use their `clear!`).
  def self.clear_caches!
    Parser.clear_caches!
    StructFactory.clear_caches!
    Domains::DynamicFinders.clear_caches!
  end
end

# const_missing is kept as a fallback only. wake_up's bind_tables! already
# defines every schema table; this hook only fires for typo'd constants
# (where Diamond can't help) or in older code paths. Either way it raises
# NameError cleanly instead of silently inventing proxies.
module DiamondConstMissing
  def const_missing(name)
    table_sym = name.to_s.downcase.to_sym

    if Diamond.engine && Diamond.engine.schema_cache.key?(table_sym)
      # schema had this table but it wasn't eager-bound (e.g., bind_tables!
      # ran before this table existed). bind it now.
      proxy = Diamond::Table.new(table_sym).freeze
      Object.const_set(name, proxy)
      Diamond.note_bound_table(name)
      proxy
    else
      super
    end
  end
end
Module.prepend(DiamondConstMissing)

require 'minitest/autorun'
require 'tempfile'
require_relative '../lib/diamond'

class RactorTest < Minitest::Test
  def setup
    @db_file = Tempfile.new(['diamond_ractor', '.db'])
    @db_file.close
    Diamond.wake_up(@db_file.path)

    Diamond.define_relation(:users) do |t|
      t.attribute :id, Integer, primary_key: true, nullable: false
      t.attribute :name, String
      t.attribute :age, Integer
    end
    Diamond.engine.db.execute("INSERT INTO users (id, name, age) VALUES (1, 'Arle', 16)")
    Diamond.engine.db.execute("INSERT INTO users (id, name, age) VALUES (2, 'Carbuncle', 100)")
    Diamond.engine.db.execute("INSERT INTO users (id, name, age) VALUES (3, 'Sig', 25)")
    Diamond.engine.db.execute("INSERT INTO users (id, name, age) VALUES (4, 'High', 250)")
  end

  def teardown
    @db_file.unlink
  end

  # ====================================================================
  # Shareability
  # ====================================================================

  def test_users_constant_is_ractor_shareable
    assert Ractor.shareable?(Users), "Users should be shareable across Ractors"
  end

  def test_diamond_module_is_ractor_shareable
    assert Ractor.shareable?(Diamond), "Diamond module should be shareable"
  end

  def test_diamond_ast_constants_are_shareable
    assert Ractor.shareable?(Diamond::AST::Column)
    assert Ractor.shareable?(Diamond::AST::Equality)
  end

  # NOTE: a pre-built QueryObject is NOT necessarily shareable — it has a
  # mutable @cached_result slot and the AST nodes are mutable. Workers should
  # build their own queries from the shareable Table constant; results that
  # need to cross Ractor boundaries should be the materialized Struct array.

  # ====================================================================
  # Per-Ractor engine
  # ====================================================================

  def test_worker_ractor_gets_its_own_engine
    main_engine_id = Diamond.engine.object_id
    r = Ractor.new { Diamond.engine.object_id }
    refute_equal main_engine_id, r.value, "worker should not share the main Ractor's engine"
  end

  def test_worker_ractor_sees_same_schema
    r = Ractor.new { Diamond.engine.schema_cache.keys.sort }
    assert_equal [:users], r.value
  end

  # ====================================================================
  # Workers can read
  # ====================================================================

  def test_worker_can_run_a_simple_count
    r = Ractor.new(Users) do |table|
      table.count
    end
    assert_equal 4, r.value
  end

  def test_worker_can_run_a_where_query
    r = Ractor.new(Users) do |table|
      table.where { age > 20 }.materialize.map(&:name).sort
    end
    assert_equal %w[Carbuncle High Sig], r.value
  end

  def test_worker_can_use_likes_operator_in_its_own_ractor
    # Like is a built-in; the worker Ractor's registry should pick it up
    # automatically on first access.
    r = Ractor.new(Users) do |table|
      table.where { name =~ /^A/ }.materialize.map(&:name)
    end
    assert_equal ['Arle'], r.value
  end

  def test_worker_can_run_a_between_query
    r = Ractor.new(Users) do |table|
      table.where { age.between?(20, 200) }.materialize.map(&:name).sort
    end
    assert_equal %w[Carbuncle Sig], r.value
  end

  def test_worker_can_use_or_chain
    r = Ractor.new(Users) do |table|
      q = table.where { name == 'Arle' }
      q = q.or { name == 'High' }
      q.materialize.map(&:name).sort
    end
    assert_equal %w[Arle High], r.value
  end

  # ====================================================================
  # Parser caches are per-Ractor
  # ====================================================================

  def test_parser_cache_is_per_ractor
    # warm main's where cache
    Users.where { id == 1 }
    main_cache = Diamond::Parser.cache_for(:where)
    refute_empty main_cache

    # worker should have its OWN (empty) cache initially
    r = Ractor.new do
      Diamond::Parser.cache_for(:where)
    end
    worker_cache = r.value
    assert_kind_of Hash, worker_cache
    refute_same main_cache.object_id, worker_cache.object_id
  end

  # ====================================================================
  # Concurrent reads
  # ====================================================================

  def test_multiple_workers_read_concurrently
    readers = 4.times.map do |i|
      Ractor.new(Users, i) do |table, idx|
        table.where { age > 0 }.materialize.size
      end
    end
    counts = readers.map(&:value)
    assert_equal [4, 4, 4, 4], counts
  end

  # ====================================================================
  # Built-in operators are present in workers
  # ====================================================================

  def test_like_built_in_is_present_in_worker_registry
    r = Ractor.new do
      Diamond::Parser::WhereOperators.handlers.map { |h| h.name }
    end
    handlers = r.value
    assert_includes handlers, "Diamond::Operators::Like"
  end

  # ====================================================================
  # Dynamic finders in workers (per-Ractor FINDER_COLS_CACHE)
  # ====================================================================

  def test_worker_can_use_dynamic_finders
    r = Ractor.new(Users) do |table|
      table.by_id(1).materialize.map(&:name)
    end
    assert_equal ['Arle'], r.value
  end

  def test_worker_finder_cache_does_not_collide_with_main
    # warm main's finder cache
    Users.by_id(1)
    main_cache = Diamond::Domains::DynamicFinders.cache
    refute_empty main_cache

    # worker has its own cache
    r = Ractor.new do
      Diamond::Domains::DynamicFinders.cache
    end
    worker_cache = r.value
    assert_kind_of Hash, worker_cache
    refute_same main_cache.object_id, worker_cache.object_id
  end

  # ====================================================================
  # Late-defined tables bind eagerly so workers don't fall through const_missing
  # ====================================================================

  def test_late_defined_table_binds_const_eagerly
    Diamond.define_relation(:late_users) do |t|
      t.attribute :id, Integer, primary_key: true, nullable: false
      t.attribute :name, String
    end
    Diamond.engine.db.execute("INSERT INTO late_users (id, name) VALUES (1, 'Late')")

    # the constant must be visible from a worker, not just from main
    r = Ractor.new { Object.const_get(:LateUsers).count }
    assert_equal 1, r.value
  end
end

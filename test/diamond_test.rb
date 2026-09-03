require 'minitest/autorun'

require_relative '../lib/diamond'

class DiamondTest < Minitest::Test
  def setup
    Diamond.wake_up(':memory:')

    Diamond.define_relation(:users) do |t|
      t.attribute :id, Integer, primary_key: true, nullable: false
      t.attribute :name, String
      t.attribute :age, Integer
    end

    Diamond.define_relation(:categories) do |t|
      t.attribute :id, Integer, primary_key: true, nullable: false
      t.attribute :name, String
      t.attribute :parent_id, Integer
    end

    Diamond.define_relation(:posts) do |t|
      t.attribute :id, Integer, primary_key: true, nullable: false
      t.attribute :title, String
      t.attribute :user_id, Integer
      t.foreign_key :user_id, :users
    end

    Diamond.engine.db.execute("INSERT INTO users (id, name, age) VALUES (1, 'Arle', 16)")
    Diamond.engine.db.execute("INSERT INTO users (id, name, age) VALUES (2, 'Carbuncle', 100)")
    Diamond.engine.db.execute("INSERT INTO users (id, name, age) VALUES (3, 'Sig', 25)")
    Diamond.engine.db.execute("INSERT INTO users (id, name, age) VALUES (4, 'High', 250)")

    Diamond.engine.db.execute("INSERT INTO categories (id, name, parent_id) VALUES (10, 'Root', NULL)")
    Diamond.engine.db.execute("INSERT INTO categories (id, name, parent_id) VALUES (11, 'Child1', 10)")
    Diamond.engine.db.execute("INSERT INTO categories (id, name, parent_id) VALUES (12, 'Child2', 10)")
    Diamond.engine.db.execute("INSERT INTO categories (id, name, parent_id) VALUES (13, 'Grandchild', 11)")
  end

  # ====================================================================
  # DDL
  # ====================================================================

  def test_engine_initialized
    assert_kind_of Diamond::Engine, Diamond.engine
    assert_kind_of SQLite3::Database, Diamond.engine.db
    assert_kind_of Hash, Diamond.engine.schema_cache
    assert_kind_of Hash, Diamond.engine.foreign_keys
  end

  def test_define_relation_returns_ast_node
    ast = Diamond.define_relation(:widgets) do |t|
      t.attribute :id, Integer, primary_key: true, nullable: false
      t.attribute :label, String
    end
    assert_kind_of Diamond::AST::DefineRelation, ast
    assert_equal :widgets, ast.name
    assert(ast.columns.all? { |c| c.is_a?(Diamond::AST::ColumnDefinition) })
  end

  def test_define_relation_populates_schema_cache
    Diamond.define_relation(:widgets) do |t|
      t.attribute :id, Integer, primary_key: true, nullable: false
      t.attribute :label, String
    end
    assert Diamond.engine.schema_cache.key?(:widgets)
    assert_equal :id, Diamond.engine.schema_cache[:widgets][:primary_key]
      assert_equal [:id, :label], Diamond.engine.schema_cache[:widgets][:columns].sort
  end

  def test_ddl_no_receiver_form_supported
    Diamond.define_relation(:standalone) do
      attribute :id, Integer, primary_key: true, nullable: false
      attribute :label, String
    end
    assert_equal :id, Diamond.engine.schema_cache[:standalone][:primary_key]
  end

  def test_ddl_primary_key_builder
    Diamond.define_relation(:with_pk) do |t|
      primary_key :id
      attribute :name, String
    end
    assert_equal :id, Diamond.engine.schema_cache[:with_pk][:primary_key]
    assert_equal [:id, :name], Diamond.engine.schema_cache[:with_pk][:columns]
  end

  def test_ddl_foreign_key_populates_fk_cache
    fks = Diamond.engine.foreign_keys[:posts]
    assert_equal 1, fks.size
    assert_equal :user_id, fks.first[:local]
    assert_equal :users, fks.first[:ref_table]
    assert_equal :id, fks.first[:ref_col]
  end

  def test_const_missing_resolves_table_constants
    assert_kind_of Diamond::Table, Users
    assert_kind_of Diamond::Table, Posts
    assert_equal :users, Users.name
    assert_equal :posts, Posts.name
  end

  def test_const_missing_raises_for_unknown
    assert_raises(NameError) { GhostTable }
  end

  def test_ddl_compiler_emits_expected_sql
    ast = Diamond._build_relation(:widgets) do |t|
      t.attribute :id, Integer, primary_key: true, nullable: false
      t.attribute :label, String, nullable: false
      t.attribute :price, Float
      t.foreign_key :owner_id, :users
    end
    sql, params = Diamond::Compiler::DDL.compile(ast)
    expected = "CREATE TABLE widgets (id INTEGER PRIMARY KEY, label TEXT NOT NULL, price REAL, FOREIGN KEY (owner_id) REFERENCES users(id))"
    assert_equal expected, sql
    assert_equal [], params
  end

  def test_ddl_type_spellcheck_raises_with_suggestion
    err = assert_raises(ArgumentError) do
      Diamond.define_relation(:typo) do |t|
        t.attribute :id, Integre
      end
    end
    assert_match(/Unknown type|Integer/, err.message)
  end

  def test_reload_schema_refreshes_caches
    Diamond.define_relation(:comments) do |t|
      t.attribute :id, Integer, primary_key: true, nullable: false
      t.attribute :body, String
    end
    assert Diamond.engine.schema_cache.key?(:comments)
    Diamond.engine.reload_schema!
    assert Diamond.engine.schema_cache.key?(:comments)
    assert Diamond.engine.foreign_keys.key?(:comments)
  end

  # ====================================================================
  # DDL — FK Actions & Indexes
  # ====================================================================

  def test_foreign_key_on_delete_cascade_emits_clause
    ast = Diamond._build_relation(:widgets) do |t|
      t.attribute :id, Integer, primary_key: true, nullable: false
      t.attribute :owner_id, Integer
      t.foreign_key :owner_id, :owners, on_delete: :cascade
    end
    sql, _ = Diamond::Compiler::DDL.compile(ast)
    assert_match(/ON DELETE CASCADE/, sql)
  end

  def test_foreign_key_on_update_set_null_emits_clause
    ast = Diamond._build_relation(:widgets) do |t|
      t.attribute :id, Integer, primary_key: true, nullable: false
      t.attribute :owner_id, Integer
      t.foreign_key :owner_id, :owners, on_update: :set_null
    end
    sql, _ = Diamond::Compiler::DDL.compile(ast)
    assert_match(/ON UPDATE SET NULL/, sql)
  end

  def test_foreign_key_without_actions_emits_no_clause
    ast = Diamond._build_relation(:widgets) do |t|
      t.attribute :id, Integer, primary_key: true, nullable: false
      t.attribute :owner_id, Integer
      t.foreign_key :owner_id, :owners
    end
    sql, _ = Diamond::Compiler::DDL.compile(ast)
    refute_match(/ON (DELETE|UPDATE)/, sql)
  end

  def test_foreign_key_unknown_action_raises_at_parse_time
    err = assert_raises(ArgumentError) do
      Diamond.define_relation(:widgets) do |t|
        t.attribute :id, Integer, primary_key: true, nullable: false
        t.attribute :owner_id, Integer
        t.foreign_key :owner_id, :owners, on_delete: :bogus
      end
    end
    assert_match(/unknown on_delete action/, err.message)
  end

  def test_inline_index_emits_create_unique_index
    Diamond.define_relation(:widgets) do |t|
      t.attribute :id, Integer, primary_key: true, nullable: false
      t.attribute :name, String
      t.index :name, unique: true, name: :idx_widgets_name
    end
    indexes = Diamond.engine.db.execute("PRAGMA index_list(widgets)")
    names = indexes.map { |row| row['name'] }
    assert_includes names, 'idx_widgets_name'
    unique_row = indexes.find { |row| row['name'] == 'idx_widgets_name' }
    assert_equal 1, unique_row['unique']
  end

  def test_inline_index_non_unique_emits_plain_index
    Diamond.define_relation(:widgets2) do |t|
      t.attribute :id, Integer, primary_key: true, nullable: false
      t.attribute :a, Integer
      t.attribute :b, Integer
      t.index :a, :b, name: :idx_w2_ab
    end
    indexes = Diamond.engine.db.execute("PRAGMA index_list(widgets2)")
    row = indexes.find { |r| r['name'] == 'idx_w2_ab' }
    assert row, "expected idx_w2_ab in #{indexes.inspect}"
    assert_equal 0, row['unique']
  end

  def test_top_level_create_index_via_diamond_method
    Diamond.define_relation(:widgets3) do |t|
      t.attribute :id, Integer, primary_key: true, nullable: false
      t.attribute :a, Integer
    end
    Diamond.create_index :widgets3, [:a], unique: true, name: :idx_w3_a
    row = Diamond.engine.db.execute("PRAGMA index_list(widgets3)").find { |r| r['name'] == 'idx_w3_a' }
    assert row
    assert_equal 1, row['unique']
  end

  def test_create_index_requires_name_kwarg
    Diamond.define_relation(:widgets4) do |t|
      t.attribute :id, Integer, primary_key: true, nullable: false
    end
    assert_raises(ArgumentError) { Diamond.create_index :widgets4, [:id] }
  end

  def test_wake_up_enables_foreign_keys_pragma
    Diamond.wake_up(':memory:')
    row = Diamond.engine.db.execute('PRAGMA foreign_keys').first
    assert_equal 1, row.values.first,
                 "PRAGMA should be ON after wake_up so FK actions enforce"
  end

  # ====================================================================
  # DQL — Where / Find / Materialize
  # ====================================================================

  def test_where_is_lazy_and_returns_query_object
    q = Users.where { age > 15 }
    assert_kind_of Diamond::QueryObject, q
    assert_equal 1, q.ast.size
    assert_kind_of Diamond::AST::Where, q.ast.first
    assert_nil q.instance_variable_get(:@cached_result)
  end

  def test_where_materialize_returns_frozen_structs
    users = Users.where { age > 15 }.materialize
    assert_equal 4, users.size
    users.each do |u|
      assert_kind_of Struct, u
      assert u.frozen?
      assert_operator u.age, :>, 15
    end
  end

  def test_compound_condition_with_native_and
    q = Users.where { (age > 15) && (name == "Arle") }
    sql, params = Diamond::Compiler::Base.compile(q.table, q.ast)
    assert_equal "SELECT * FROM users WHERE (age > ? AND name = ?)", sql
    assert_equal [15, "Arle"], params
    assert_equal "Arle", q.first.name
  end

  def test_bitwise_and_emits_same_sql_as_native_and
    q_native = Users.where { (age > 15) && (name == "Arle") }
    q_bit    = Users.where { (age > 15) & (name == "Arle") }
    sql_n, params_n = Diamond::Compiler::Base.compile(q_native.table, q_native.ast)
    sql_b, params_b = Diamond::Compiler::Base.compile(q_bit.table, q_bit.ast)
    assert_equal sql_n, sql_b
    assert_equal params_n, params_b
  end

  def test_find_returns_lazy_query
    q = Users.find(1)
    assert_kind_of Diamond::QueryObject, q
    assert_kind_of Diamond::AST::Where, q.ast.first
    assert_equal :id, q.ast.first.condition.left.name
    assert_equal 1, q.ast.first.condition.right.value
  end

  def test_find_lazy_proxy_returns_attribute_via_method_missing
    assert_equal "Arle", Users.find(1).name
  end

  def test_find_missing_raises_record_not_found
    assert_raises(Diamond::RecordNotFound) { Users.find(99999).name }
  end

  def test_where_typo_caught_at_parse_time
    err = assert_raises(Diamond::UnknownColumnError) { Users.where { naem == "Arle" } }
    assert_match(/Did you mean 'name'\?/, err.message)
  end

  def test_where_query_is_composable
    base = Users.where { age > 15 }
    composed = base.where { name == "Carbuncle" }
    assert_equal 1, base.ast.size
    assert_equal 2, composed.ast.size
    assert_equal "Carbuncle", composed.first.name
  end

  # IN clause (array overload + explicit .in method + NOT IN)

  def test_in_via_array_overload
    q = Users.where { id == [1, 2] }
    sql, params = Diamond::Compiler::Base.compile(q.table, q.ast)
    assert_equal "SELECT * FROM users WHERE id IN (?, ?)", sql
    assert_equal [1, 2], params
    assert_equal 2, q.materialize.size
  end

  def test_in_via_explicit_in_method
    q = Users.where { id.in(1, 2) }
    sql, params = Diamond::Compiler::Base.compile(q.table, q.ast)
    assert_equal "SELECT * FROM users WHERE id IN (?, ?)", sql
    assert_equal [1, 2], params
  end

  def test_array_overload_and_explicit_in_produce_identical_sql
    a = Users.where { id == [1, 2] }
    b = Users.where { id.in(1, 2) }
    sql_a, params_a = Diamond::Compiler::Base.compile(a.table, a.ast)
    sql_b, params_b = Diamond::Compiler::Base.compile(b.table, b.ast)
    assert_equal sql_a, sql_b
    assert_equal params_a, params_b
  end

  def test_in_with_string_literals
    q = Users.where { name == ["Arle", "Carbuncle"] }
    sql, params = Diamond::Compiler::Base.compile(q.table, q.ast)
    assert_equal "SELECT * FROM users WHERE name IN (?, ?)", sql
    assert_equal ["Arle", "Carbuncle"], params
  end

  def test_in_with_empty_array_overload_generates_no_match_predicate
    q = Users.where { id == [] }
    sql, params = Diamond::Compiler::Base.compile(q.table, q.ast)
    assert_equal "SELECT * FROM users WHERE 1=0", sql
    assert_equal [], params
    assert_equal [], q.materialize
  end

  def test_in_with_empty_explicit_call_generates_no_match_predicate
    q = Users.where { id.in() }
    sql, _ = Diamond::Compiler::Base.compile(q.table, q.ast)
    assert_equal "SELECT * FROM users WHERE 1=0", sql
  end

  def test_in_with_single_value
    q = Users.where { id.in(5) }
    sql, params = Diamond::Compiler::Base.compile(q.table, q.ast)
    assert_equal "SELECT * FROM users WHERE id IN (?)", sql
    assert_equal [5], params
  end

  def test_in_with_five_values_generates_five_placeholders
    q = Users.where { id.in(1, 2, 3, 4, 5) }
    sql, params = Diamond::Compiler::Base.compile(q.table, q.ast)
    assert_equal "SELECT * FROM users WHERE id IN (?, ?, ?, ?, ?)", sql
    assert_equal [1, 2, 3, 4, 5], params
  end

  def test_in_chains_with_other_conditions
    q = Users.where { id.in(1, 2) }
    q = q.where { name == "Arle" }
    sql, params = Diamond::Compiler::Base.compile(q.table, q.ast)
    assert_equal "SELECT * FROM users WHERE id IN (?, ?) AND name = ?", sql
    assert_equal [1, 2, "Arle"], params
  end

  def test_in_array_element_may_be_a_column_reference
    q = Users.where { id == [id] }
    sql, params = Diamond::Compiler::Base.compile(q.table, q.ast)
    assert_equal "SELECT * FROM users WHERE id IN (id)", sql
    assert_equal [], params
    assert_equal 4, q.materialize.size, "id IN (id) is tautologically true"
  end

  def test_not_in_via_unequal_array_overload
    q = Users.where { id != [1, 2] }
    sql, params = Diamond::Compiler::Base.compile(q.table, q.ast)
    assert_equal "SELECT * FROM users WHERE id NOT IN (?, ?)", sql
    assert_equal [1, 2], params
    assert_equal 2, q.materialize.size, "3 of 4 rows excluded"
  end

  def test_not_in_with_empty_array_generates_match_all_predicate
    q = Users.where { id != [] }
    sql, params = Diamond::Compiler::Base.compile(q.table, q.ast)
    assert_equal "SELECT * FROM users WHERE 1=1", sql
    assert_equal [], params
    assert_equal 4, q.materialize.size, "NOT IN () is tautologically true"
  end

  def test_not_equal_with_scalar_unchanged
    q = Users.where { id != 5 }
    sql, params = Diamond::Compiler::Base.compile(q.table, q.ast)
    assert_equal "SELECT * FROM users WHERE id <> ?", sql
    assert_equal [5], params
  end

  # ====================================================================
  # DQL — Joins
  # ====================================================================

  def test_auto_join_resolves_fk_via_cache
    q = Users.join(:posts)
    assert_kind_of Diamond::AST::Join, q.ast.first
    assert_equal :inner, q.ast.first.type
    assert_equal({ user_id: :id }, q.ast.first.on)
    sql, _ = Diamond::Compiler::Base.compile(q.table, q.ast)
    assert_equal "SELECT * FROM users INNER JOIN posts ON posts.user_id = users.id", sql
  end

  def test_explicit_join_with_overrides
    q = Users.join(:posts, on: { id: :user_id }, type: :left)
    sql, _ = Diamond::Compiler::Base.compile(q.table, q.ast)
    assert_equal "SELECT * FROM users LEFT OUTER JOIN posts ON posts.id = users.user_id", sql
  end

  def test_auto_join_failure_raises_table_not_found
    err = assert_raises(Diamond::TableNotFound) { Users.join(:categories) }
    assert_match(/No foreign key connects/, err.message)
  end

  # ====================================================================
  # DQL — Derive
  # ====================================================================

  def test_derive_aggregation_emits_count
    q = Users.derive { count(id) }
    sql, params = Diamond::Compiler::Base.compile(q.table, q.ast)
    assert_equal "SELECT COUNT(id) FROM users", sql
    assert_equal [], params
  end

  def test_derive_bare_column_supported
    q = Users.find(1).derive { name }
    sql, params = Diamond::Compiler::Base.compile(q.table, q.ast)
    assert_equal "SELECT name FROM users WHERE id = ?", sql
    assert_equal [1], params
  end

  # ====================================================================
  # DML — Create / Update / Delete
  # ====================================================================

  def test_create_returns_frozen_struct
    u = Users.create(name: "Lemres", age: 30)
    assert_kind_of Struct, u
    assert u.frozen?
    assert_equal 5, u.id, "id 5 because seed inserts ids 1-4"
    assert_equal "Lemres", u.name
    assert_equal 30, u.age
    assert_equal "Lemres", Users.find(5).first.name
  end

  def test_update_block_bareword_form
    assert_equal 1, Users.where { id == 1 }.update { age 17 }
    assert_equal 17, Users.find(1).first.age
  end

  def test_update_block_with_multiple_columns
    Users.where { id == 2 }.update { age 200; name "Carby" }
    assert_equal 200, Users.find(2).first.age
    assert_equal "Carby", Users.find(2).first.name
  end

  def test_update_block_assignment_form
    # Trailing `age` is a LocalVariableReadNode — Diamond treats it as a
    # no-op reference, and it silences Ruby's "assigned but unused" warning.
    count = Users.where { id == 3 }.update { age = 26; age }
    assert_equal 1, count
    assert_equal 26, Users.find(3).first.age
  end

  def test_update_without_where_affects_all_rows
    Users.update { age 0 }
    ages = Diamond::QueryObject.new(Users).materialize.map(&:age)
    assert_equal [0, 0, 0, 0], ages
  end

  def test_update_typo_raises_unknown_column
    err = assert_raises(Diamond::UnknownColumnError) { Users.where { id == 1 }.update { agi 99 } }
    assert_match(/Did you mean 'age'\?/, err.message)
  end

  def test_delete_with_where_returns_count
    Diamond.engine.db.execute("INSERT INTO users (id, name, age) VALUES (100, 'Bot1', 5)")
    Diamond.engine.db.execute("INSERT INTO users (id, name, age) VALUES (101, 'Bot2', 6)")
    assert_equal 2, Users.where { age < 10 }.delete
    assert Users.where { age < 10 }.materialize.empty?
  end

  def test_delete_without_where_removes_all
    Users.delete
    assert Diamond::QueryObject.new(Users).materialize.empty?
  end

  def test_update_invalidates_cache
    q = Users.where { age > 10 }
    q.materialize
    refute_nil q.instance_variable_get(:@cached_result)
    q.update { age 99 }
    assert_nil q.instance_variable_get(:@cached_result)
    assert_equal 99, q.materialize.first.age
  end

  # ====================================================================
  # CTE
  # ====================================================================

  def test_with_macro_returns_query_object
    active = Users.where { age > 10 }
    q = Diamond.with(active: active) { |d| d.from(:active) }
    assert_kind_of Diamond::QueryObject, q
    assert_equal 4, q.materialize.size, "all 4 users have age > 10"
  end

  def test_cte_parameter_interleaving
    cte_q = Diamond.with(over10: Users.where { age > 10 }) do |d|
      d.from(:over10).where { name == "Arle" }
    end
    cte_q.instance_variable_set(:@cached_result, nil)
    sql, params = Diamond::Compiler::Base.compile(cte_q.table, cte_q.ast)
    assert_equal "WITH over10 AS (SELECT * FROM users WHERE age > ?) SELECT * FROM over10 WHERE name = ?", sql
    assert_equal [10, "Arle"], params
  end

  def test_recursive_cte
    base = Categories.where { parent_id == nil }
    recursive = Categories.from_cte(:tree)
    recursive_q = Diamond.with_recursive(:tree, base, recursive)
    recursive_q.instance_variable_set(:@cached_result, nil)
    sql, params = Diamond::Compiler::Base.compile(recursive_q.table, recursive_q.ast)
    expected = "WITH RECURSIVE tree AS (SELECT * FROM categories WHERE parent_id = ? UNION ALL SELECT * FROM tree) SELECT * FROM tree"
    assert_equal expected, sql
    assert_equal [nil], params
  end

  # ====================================================================
  # Window Functions
  # ====================================================================

  def test_window_function_with_partition_and_order
    q = Users.derive { row_number.over(partition_by: :age, order: :id) }
    sql, _ = Diamond::Compiler::Base.compile(q.table, q.ast)
    assert_equal "SELECT ROW_NUMBER() OVER (PARTITION BY age ORDER BY id) FROM users", sql
  end

  def test_window_function_with_only_order
    q = Users.derive { row_number.over(order: :id) }
    sql, _ = Diamond::Compiler::Base.compile(q.table, q.ast)
    assert_equal "SELECT ROW_NUMBER() OVER (ORDER BY id) FROM users", sql
  end

  # ====================================================================
  # Multi-Statement Derive
  # ====================================================================

  def test_multi_statement_aggregation_derives_single_row
    q = Users.derive { count(id); max(age); min(age) }
    sql, _ = Diamond::Compiler::Base.compile(q.table, q.ast)
    assert_equal "SELECT COUNT(id), MAX(age), MIN(age) FROM users", sql
    row = q.first
    assert_respond_to row, :count_id
    assert_respond_to row, :max_age
    assert_respond_to row, :min_age
    assert_equal 4, row.count_id, "4 rows in seed"
    assert_equal 250, row.max_age
    assert_equal 16, row.min_age
  end

  def test_multi_statement_bare_columns
    q = Users.find(1).derive { id; name }
    sql, params = Diamond::Compiler::Base.compile(q.table, q.ast)
    assert_equal "SELECT id, name FROM users WHERE id = ?", sql
    assert_equal [1], params
    row = q.first
    assert_equal 1, row.id
    assert_equal "Arle", row.name
    refute_respond_to row, :age
  end

  def test_mixed_multi_statement_derive
    q = Users.find(1).derive { id; count(age) }
    row = q.first
    assert_equal 1, row.id
    assert_equal 1, row.count_age
  end

  # ====================================================================
  # Dynamic Finders
  # ====================================================================

  def test_by_single_column_returns_lazy_query
    q = Users.by_name("Arle")
    assert_kind_of Diamond::QueryObject, q
    assert_kind_of Diamond::AST::Where, q.ast.first
    results = q.materialize
    assert_equal 1, results.size
    assert_equal "Arle", results.first.name
  end

  def test_by_chains_multiple_columns_with_and
    q = Users.by_name_and_age("Arle", 16)
    assert_equal 1, q.materialize.size
    assert_equal "Arle", q.first.name
  end

  def test_by_typo_raises_unknown_column_with_did_you_mean
    err = assert_raises(Diamond::UnknownColumnError) { Users.by_naem("Arle") }
    assert_match(/Did you mean 'name'\?/, err.message)
  end

  def test_by_composes_with_derive
    results = Users.by_name("Arle").derive(:age).materialize
    assert_equal 1, results.size
    assert_equal 16, results.first.age
  end

  def test_by_with_no_columns_raises_argument_error
    assert_raises(ArgumentError) { Users.by_ }
  end

  def test_by_arity_mismatch_raises_argument_error
    assert_raises(ArgumentError) { Users.by_name }
    assert_raises(ArgumentError) { Users.by_name("a", "b") }
  end

  def test_by_works_on_queryobject_for_composition
    q = Users.where { age > 10 }.by_name("Arle")
    assert_equal 1, q.materialize.size
    assert_equal 16, q.first.age
  end

  def test_respond_to_recognizes_by_prefix
    assert Users.respond_to?(:by_name)
    assert Users.respond_to?(:by_name_and_age)
    refute Users.respond_to?(:nonexistent_method)
  end

  # ====================================================================
  # Honey Batch: order / limit / offset
  # ====================================================================

  def test_order_limit_offset_chained_sql
    q = Users.where { age > 10 }.order(:name, age: :desc).limit(5).offset(2)
    assert_kind_of Diamond::QueryObject, q
    sql, params = Diamond::Compiler::Base.compile(q.table, q.ast)
    assert_equal "SELECT * FROM users WHERE age > ? ORDER BY name ASC, age DESC LIMIT ? OFFSET ?", sql
    assert_equal [10, 5, 2], params
  end

  def test_order_with_only_symbols_defaults_to_asc
    q = Users.order(:name)
    sql, _ = Diamond::Compiler::Base.compile(q.table, q.ast)
    assert_equal "SELECT * FROM users ORDER BY name ASC", sql
  end

  def test_order_with_only_kwargs
    q = Users.order(name: :asc, age: :desc)
    sql, _ = Diamond::Compiler::Base.compile(q.table, q.ast)
    assert_equal "SELECT * FROM users ORDER BY name ASC, age DESC", sql
  end

  def test_order_with_invalid_direction_raises
    assert_raises(ArgumentError) { Users.order(name: :sideways) }
  end

  def test_order_typo_raises_with_suggestion
    err = assert_raises(Diamond::UnknownColumnError) { Users.order(:naem) }
    assert_match(/Did you mean 'name'\?/, err.message)
  end

  def test_order_with_unknown_kwarg_column_raises
    assert_raises(Diamond::UnknownColumnError) { Users.order(bad: :asc) }
  end

  def test_limit_builds_ast_limit_node
    q = Users.limit(5)
    assert_kind_of Diamond::AST::Limit, q.ast.first
    assert_equal 5, q.ast.first.value
  end

  def test_offset_builds_ast_offset_node
    q = Users.offset(2)
    assert_kind_of Diamond::AST::Offset, q.ast.first
    assert_equal 2, q.ast.first.value
  end

  def test_limit_rejects_non_integer
    assert_raises(ArgumentError) { Users.limit("five") }
  end

  def test_limit_rejects_negative
    assert_raises(ArgumentError) { Users.limit(-1) }
  end

  def test_offset_rejects_negative
    assert_raises(ArgumentError) { Users.offset(-5) }
  end

  def test_multiple_limit_uses_last_wins
    q = Users.limit(5).limit(10)
    limit_nodes = q.ast.select { |n| n.is_a?(Diamond::AST::Limit) }
    assert_equal 1, limit_nodes.size, "Limit replaced in chain (not appended)"
    assert_equal 10, limit_nodes.first.value
  end

  def test_multiple_order_combines_specs
    q = Users.order(:name).order(:age)
    order_nodes = q.ast.select { |n| n.is_a?(Diamond::AST::Order) }
    assert_equal 1, order_nodes.size, "Order replaced in chain"
    assert_equal [[:name, :asc], [:age, :asc]], order_nodes.first.specs
  end

  def test_derive_twice_raises_on_duplicate_projection
    assert_raises(RuntimeError) { Users.derive(:name).derive(:age) }
  end

  # ====================================================================
  # Honey Batch: pluck / exists? / count / first / last
  # ====================================================================

  def test_pluck_single_column_returns_flat_array
    names = Users.pluck(:name)
    assert_equal ["Arle", "Carbuncle", "Sig", "High"], names
  end

  def test_pluck_single_column_with_where
    names = Users.where { age > 100 }.pluck(:name)
    assert_equal ["High"], names
  end

  def test_pluck_multiple_columns_returns_array_of_arrays
    rows = Users.pluck(:name, :age)
    assert_equal [["Arle", 16], ["Carbuncle", 100], ["Sig", 25], ["High", 250]], rows
  end

  def test_pluck_with_unknown_column_raises
    err = assert_raises(Diamond::UnknownColumnError) { Users.pluck(:naem) }
    assert_match(/Did you mean 'name'\?/, err.message)
  end

  def test_pluck_chains_with_where
    names = Users.where { age > 100 }.pluck(:name)
    assert_equal ["High"], names
  end

  def test_exists_returns_true_when_rows_match
    assert Users.where { age > 100 }.exists?
  end

  def test_exists_returns_false_when_no_rows
    refute Users.where { age > 999 }.exists?
  end

  def test_count_total
    assert_equal 4, Users.count
  end

  def test_count_with_where
    assert_equal 1, Users.where { age > 100 }.count
    assert_equal 0, Users.where { age > 1000 }.count
  end

  def test_first_returns_single_struct_for_lowest_id
    first = Users.first
    assert_kind_of Struct, first
    assert_equal 1, first.id
    assert_equal "Arle", first.name
  end

  def test_first_with_n_returns_array
    first_two = Users.first(2)
    assert_kind_of Array, first_two
    assert_equal 2, first_two.size
    assert_equal [1, 2], first_two.map(&:id)
  end

  def test_first_with_n_one_returns_single_struct
    assert_kind_of Struct, Users.first(1)
  end

  def test_first_with_where
    first = Users.where { age > 100 }.first
    assert_kind_of Struct, first
    assert_equal "High", first.name
  end

  def test_first_with_explicit_order_respects_user_order
    first = Users.order(:age).first
    assert_equal "Arle", first.name, "youngest by age"
  end

  def test_last_returns_single_struct_for_highest_id
    last = Users.last
    assert_kind_of Struct, last
    assert_equal 4, last.id
    assert_equal "High", last.name
  end

  def test_last_with_n_returns_array_in_ascending_id_order
    last_two = Users.last(2)
    assert_kind_of Array, last_two
    assert_equal 2, last_two.size
    assert_equal [3, 4], last_two.map(&:id), "should be reversed (Sig, High)"
  end

  def test_last_with_where
    last = Users.where { age > 10 }.last
    assert_equal "High", last.name
  end

  # ====================================================================
  # Streaming Edge — QueryObject#each (returns Enumerable Cursor)
  # ====================================================================

  def test_each_with_block_yields_frozen_structs
    yielded = []
    Users.where { age > 10 }.each { |u| yielded << u }
    assert_equal 4, yielded.size
    yielded.each do |u|
      assert_kind_of Struct, u
      assert u.frozen?, "streamed struct must be frozen"
    end
  end

  def test_each_without_block_returns_cursor_that_includes_enumerable
    cursor = Users.where { age > 10 }.each
    assert_kind_of Diamond::Cursor, cursor
    assert cursor.is_a?(Enumerable)
  end

  def test_each_cursor_supports_first_n
    collected = Users.where { age > 10 }.each.first(3)
    assert_equal 3, collected.size
    collected.each { |u| assert_kind_of Struct, u }
  end

  def test_each_cursor_supports_lazy_chain
    collected = Users.each.lazy.select { |u| u.age > 50 }.first(2)
    assert_equal 2, collected.size
    names = collected.map(&:name)
    assert_includes names, 'High'
    assert_includes names, 'Carbuncle'
  end

  def test_each_with_empty_result_yields_nothing
    yielded = []
    Users.where { age > 999 }.each { |u| yielded << u }
    assert_equal [], yielded
  end

  def test_each_re_executes_per_call_no_caching
    first_size  = Users.each.to_a.size
    Diamond.engine.db.execute("INSERT INTO users (id, name, age) VALUES (99, 'Late', 7)")
    second_size = Users.each.to_a.size
    assert_equal 4, first_size
    assert_equal 5, second_size, "each must re-execute (declarative purity)"
  end

  def test_each_on_table_via_dsl
    yielded = []
    Users.each { |u| yielded << u.id }
    assert_equal [1, 2, 3, 4], yielded
  end

  def test_each_cursor_close_is_idempotent
    # After ensure closes the statement, closing again must be a no-op
    # (Cursor checks closed? before acting).
    first = Users.each.first
    assert_kind_of Struct, first
    # A follow-up query proves the cursor closed cleanly (no leaked handle).
    assert_equal 4, Users.count
  end

  # ====================================================================
  # Prism Refactor Invariants
  # ====================================================================

  def test_no_instance_eval_anywhere_in_lib
    offenders = Dir["lib/**/*.rb"].flat_map do |f|
      File.readlines(f).select { |line| line.include?("instance_eval") }
    end
    assert_empty offenders, "instance_eval still present: #{offenders.inspect}"
  end

  def test_no_basicobject_subclasses_in_lib
    offenders = Dir["lib/**/*.rb"].flat_map do |f|
      File.readlines(f).select { |line| line.include?("BasicObject") }
    end
    assert_empty offenders, "BasicObject still present: #{offenders.inspect}"
  end

  def test_parser_cache_hits_across_invocations
    Users.where { age > 10 }
    cache = Diamond::Parser.instance_variable_get(:@where_cache)
    refute_empty cache, "expected at least one cached where-block translation"
  end
end

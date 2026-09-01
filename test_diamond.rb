require_relative 'lib/diamond'
require 'minitest/autorun'

Diamond.wake_up(":memory:")

Diamond.create_table(:users) do |t|
  t.primary_key :id
  t.text :name
  t.integer :age
end

Diamond.create_table(:categories) do |t|
  t.primary_key :id
  t.text :name
  t.integer :parent_id
end

Diamond.create_table(:posts) do |t|
  t.primary_key :id
  t.integer :user_id
  t.text :title
  t.text :created_at
end

Diamond.engine.reload_schema!

class DiamondTest < Minitest::Test
    def setup
    # Clean slate for every test
    Diamond.engine.db.execute("DELETE FROM users")
    Diamond.engine.db.execute("INSERT INTO users (name, age) VALUES ('Arle', 16)")
    Diamond.engine.db.execute("INSERT INTO users (name, age) VALUES ('Carbuncle', 100)")
    
    # Create tables for CTE/Window tests if they don't exist
    Diamond.engine.db.execute("CREATE TABLE IF NOT EXISTS categories (id INTEGER PRIMARY KEY, name TEXT, parent_id INTEGER)")
    Diamond.engine.db.execute("CREATE TABLE IF NOT EXISTS posts (id INTEGER PRIMARY KEY, user_id INTEGER, title TEXT, created_at TEXT)")
    
    # Clear them out for clean tests
    Diamond.engine.db.execute("DELETE FROM categories")
    Diamond.engine.db.execute("DELETE FROM posts")
  end

  def test_find_generates_lazy_ast
    q = Users.find(1)
    
    assert_kind_of Diamond::QueryObject, q
    assert_nil q.instance_variable_get(:@cached_result), "Query should not be materialized yet"
    
    # Check the AST structure
    where_node = q.ast.first
    assert_kind_of Diamond::AST::Where, where_node
    assert_equal :id, where_node.condition.left.name
    assert_equal 1, where_node.condition.right.value
  end

    def test_compiler_generates_exact_sql
    q = Users.find(1)
    sql, params = Diamond::Compiler.compile(q.table, q.ast)
    
    # No parens on simple equality
    assert_equal "SELECT * FROM users WHERE id = ?", sql
    assert_equal [1], params
  end

  def test_where_block_builds_complex_ast
    q = Users.where { (age > 15) & (name == "Arle") }
    sql, params = Diamond::Compiler.compile(q.table, q.ast)
    
    # Parens on the AND block, no parens on the inner comparisons
    assert_equal "SELECT * FROM users WHERE (age > ? AND name = ?)", sql
    assert_equal [15, "Arle"], params
  end

  def test_derive_produces_projected_sql
    q = Users.find(1).derive(:name)
    sql, params = Diamond::Compiler.compile(q.table, q.ast)
    
    # No parens on simple equality
    assert_equal "SELECT name FROM users WHERE id = ?", sql
    assert_equal [1], params
  end

  def test_materialize_returns_frozen_structs
    users = Users.where { age > 10 }.materialize
    
    assert_equal 2, users.size
    users.each do |user|
      assert user.frozen?, "Struct must be frozen"
      assert_kind_of Struct, user
    end
  end

  def test_lazy_proxy_caches_on_attribute_access
    q = Users.find(1)
    
    # First access triggers execution
    name = q.name
    assert_equal "Arle", name
    
    # Check that the result was cached
    cached = q.instance_variable_get(:@cached_result)
    refute_nil cached, "Result should be cached after attribute access"
  end

  def test_struct_is_inert
    user = Users.find(1).first
    
    assert_raises Diamond::InertObjectError do
      user.save
    end
  end

  def test_typo_in_where_raises_unknown_column
    error = assert_raises Diamond::UnknownColumnError do
      Users.where { naem == "Arle" }
    end
    
    assert_match /Did you mean 'name'\?/, error.message
  end

  def test_query_composability
    base_q = Users.where { age > 10 }
    composed_q = base_q.where { name == "Carbuncle" }
    
    # Ensure base query wasn't mutated
    assert_equal 1, base_q.ast.size
    # Ensure composed query has two nodes
    assert_equal 2, composed_q.ast.size
    
    user = composed_q.first
    assert_equal "Carbuncle", user.name
  end

  def test_create_returns_frozen_struct
    user = Users.create(name: "Sig", age: 25)
    
    assert user.frozen?, "Created struct must be frozen"
    refute_nil user.id, "ID should be populated by the DB"
    assert_equal "Sig", user.name
    
    # Verify it actually hit the DB
    assert_equal "Sig", Users.find(user.id).name
  end

  def test_update_executes_immediately
    user = Users.create(name: "Dracula", age: 500)
    
    # Update via QueryObject
    rows_affected = Users.find(user.id).update(age: 501)
    
    assert_equal 1, rows_affected
    
    # Verify the DB was updated
    updated_user = Users.find(user.id).first
    assert_equal 501, updated_user.age
  end

  def test_delete_executes_immediately
    user = Users.create(name: "Ghost", age: 1)
    
    rows_affected = Users.find(user.id).delete
    assert_equal 1, rows_affected
    
    # Verify it's gone from the DB
    assert_raises Diamond::RecordNotFound do
      Users.find(user.id).name
    end
  end

  def test_update_with_where_chain
    Users.create(name: "Bot1", age: 10)
    Users.create(name: "Bot2", age: 10)
    
    rows = Users.where { age == 10 }.update(age: 11)
    assert_equal 2, rows
    
    # Verify both were updated
    count = Users.where { age == 11 }.materialize.size
    assert_equal 2, count
  end

  def test_aggregation_count
    q = Users.derive { count(id) }
    sql, params = Diamond::Compiler.compile(q.table, q.ast)
    
    assert_equal "SELECT COUNT(id) FROM users", sql
    assert_equal [], params
  end

  def test_cte_compilation
    active_users = Users.where { age > 10 }
    
    q = Diamond.with(active_users: active_users) do |d|
      d.from(:active_users).where { name == "Arle" }
    end
    
    sql, params = Diamond::Compiler.compile(q.table, q.ast)
    
    # No parens on simple comparisons inside or outside the CTE
    expected_sql = "WITH active_users AS (SELECT * FROM users WHERE age > ?) " \
                   "SELECT * FROM active_users WHERE name = ?"
                   
    assert_equal expected_sql, sql
    assert_equal [10, "Arle"], params
  end

  def test_window_function
    q = Posts.derive { row_number.over(partition_by: :user_id, order: :created_at) }
    sql, params = Diamond::Compiler.compile(q.table, q.ast)
    
    # SQL is case-insensitive, but our compiler upcases it. Adjust expectation.
    expected = "SELECT ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY created_at) FROM posts"
    assert_equal expected, sql
  end

  def test_recursive_cte
    base = Categories.where { parent_id == nil }
    recursive = Categories.from_cte(:tree)
    
    q = Diamond.with_recursive(:tree, base, recursive)
    sql, params = Diamond::Compiler.compile(q.table, q.ast)
    
    # No parens on simple equality
    expected = "WITH RECURSIVE tree AS (" \
               "SELECT * FROM categories WHERE parent_id = ? " \
               "UNION ALL " \
               "SELECT * FROM tree) " \
               "SELECT * FROM tree"
               
    assert_equal expected, sql
    assert_equal [nil], params
  end

  def test_native_and_operator
    q = Users.where { (age > 15) && (name == "Arle") }
    sql, params = Diamond::Compiler.compile(q.table, q.ast)
    
    assert_equal "SELECT * FROM users WHERE (age > ? AND name = ?)", sql
    assert_equal [15, "Arle"], params
  end

  def test_native_or_operator
    q = Users.where { (age < 10) || (name == "Carbuncle") }
    sql, params = Diamond::Compiler.compile(q.table, q.ast)
    
    assert_equal "SELECT * FROM users WHERE (age < ? OR name = ?)", sql
    assert_equal [10, "Carbuncle"], params
  end

  def test_typo_caught_at_parse_time
    assert_raises Diamond::UnknownColumnError do
      Users.where { naem == "Arle" }
    end
  end
end 

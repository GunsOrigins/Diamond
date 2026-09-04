require 'minitest/autorun'
require 'minitest/spec'

require_relative '../lib/diamond'

describe Diamond do
  before do
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
  describe "::engine" do
    it "initializes the engine and caches" do
      _(Diamond.engine).must_be_kind_of Diamond::Engine
      _(Diamond.engine.db).must_be_kind_of SQLite3::Database
      _(Diamond.engine.schema_cache).must_be_kind_of Hash
      _(Diamond.engine.foreign_keys).must_be_kind_of Hash
    end
  end

  # ====================================================================
  describe "::define_relation (DDL)" do
    it "returns an AST::DefineRelation with the table name" do
      ast = Diamond.define_relation(:widgets) do |t|
        t.attribute :id, Integer, primary_key: true, nullable: false
        t.attribute :label, String
      end
      _(ast).must_be_kind_of Diamond::AST::DefineRelation
      _(ast.name).must_equal :widgets
      _(ast.columns.all? { |c| c.is_a?(Diamond::AST::ColumnDefinition) }).must_equal true
    end

    it "populates the schema cache after define" do
      Diamond.define_relation(:widgets) do |t|
        t.attribute :id, Integer, primary_key: true, nullable: false
        t.attribute :label, String
      end
      _(Diamond.engine.schema_cache).must_include :widgets
      _(Diamond.engine.schema_cache[:widgets][:primary_key]).must_equal :id
      _(Diamond.engine.schema_cache[:widgets][:columns].sort).must_equal [:id, :label]
    end

    it "supports blocks with no |t| receiver" do
      Diamond.define_relation(:standalone) do
        attribute :id, Integer, primary_key: true, nullable: false
        attribute :label, String
      end
      _(Diamond.engine.schema_cache[:standalone][:primary_key]).must_equal :id
    end

    it "supports primary_key :id builder method" do
      Diamond.define_relation(:with_pk) do |t|
        primary_key :id
        attribute :name, String
      end
      _(Diamond.engine.schema_cache[:with_pk][:primary_key]).must_equal :id
      _(Diamond.engine.schema_cache[:with_pk][:columns]).must_equal [:id, :name]
    end

    it "populates the foreign key cache" do
      fks = Diamond.engine.foreign_keys[:posts]
      _(fks.size).must_equal 1
      _(fks.first[:local]).must_equal :user_id
      _(fks.first[:ref_table]).must_equal :users
      _(fks.first[:ref_col]).must_equal :id
    end

    it "raises ArgumentError on unknown type with DidYouMean hint" do
      err = assert_raises(ArgumentError) do
        Diamond.define_relation(:typo) { |t| t.attribute :id, Integre }
      end
      _(err.message).must_match(/Unknown type|Integer/)
    end

    it "compiles to a CREATE TABLE string with foreign keys" do
      ast = Diamond._build_relation(:widgets) do |t|
        t.attribute :id, Integer, primary_key: true, nullable: false
        t.attribute :label, String, nullable: false
        t.attribute :price, Float
        t.foreign_key :owner_id, :users
      end
      sql, params = Diamond::Compiler::DDL.compile(ast)
      expected = "CREATE TABLE widgets (id INTEGER PRIMARY KEY, label TEXT NOT NULL, price REAL, FOREIGN KEY (owner_id) REFERENCES users(id))"
      _(sql).must_equal expected
      _(params).must_equal []
    end

    it "reloads the schema cache" do
      Diamond.define_relation(:comments) do |t|
        t.attribute :id, Integer, primary_key: true, nullable: false
        t.attribute :body, String
      end
      _(Diamond.engine.schema_cache).must_include :comments
      Diamond.engine.reload_schema!
      _(Diamond.engine.schema_cache).must_include :comments
      _(Diamond.engine.foreign_keys).must_include :comments
    end
  end

  # ====================================================================
  describe "const_missing" do
    it "resolves Users and Posts to Diamond::Table" do
      _(Users).must_be_kind_of Diamond::Table
      _(Posts).must_be_kind_of Diamond::Table
      _(Users.name).must_equal :users
      _(Posts.name).must_equal :posts
    end

    it "raises NameError for unknown constants" do
      _(proc { GhostTable }).must_raise NameError
    end
  end

  # ====================================================================
  describe "::where" do
    it "is lazy until materialize" do
      q = Users.where { age > 15 }
      _(q).must_be_kind_of Diamond::QueryObject
      _(q.ast.size).must_equal 1
      _(q.ast.first).must_be_kind_of Diamond::AST::Where
      _(q.instance_variable_get(:@cached_result)).must_be_nil
    end

    it "materializes to frozen Structs" do
      users = Users.where { age > 15 }.materialize
      _(users.size).must_equal 4
      users.each do |u|
        _(u).must_be_kind_of Struct
        _(u.frozen?).must_equal true
        _(u.age).must_be :>, 15
      end
    end

    it "supports compound conditions with native &&" do
      q = Users.where { (age > 15) && (name == "Arle") }
      sql, params = Diamond::Compiler::Base.compile(q.table, q.ast)
      _(sql).must_equal "SELECT * FROM users WHERE (age > ? AND name = ?)"
      _(params).must_equal [15, "Arle"]
      _(q.first.name).must_equal "Arle"
    end

    it "supports bitwise & as AND" do
      q_native = Users.where { (age > 15) && (name == "Arle") }
      q_bit    = Users.where { (age > 15) & (name == "Arle") }
      sql_n, params_n = Diamond::Compiler::Base.compile(q_native.table, q_native.ast)
      sql_b, params_b = Diamond::Compiler::Base.compile(q_bit.table, q_bit.ast)
      _(sql_b).must_equal sql_n
      _(params_b).must_equal params_n
    end

    it "raises UnknownColumnError with DidYouMean for typos" do
      err = assert_raises(Diamond::UnknownColumnError) { Users.where { naem == "Arle" } }
      _(err.message).must_match(/Did you mean 'name'\?/)
    end

    it "is composable across chained where" do
      base = Users.where { age > 15 }
      composed = base.where { name == "Carbuncle" }
      _(base.ast.size).must_equal 1
      _(composed.ast.size).must_equal 2
      _(composed.first.name).must_equal "Carbuncle"
    end
  end

  # ====================================================================
  describe "::where IN clause" do
    it "translates id == [1, 2] to SELECT ... WHERE id IN (?, ?)" do
      q = Users.where { id == [1, 2] }
      sql, params = Diamond::Compiler::Base.compile(q.table, q.ast)
      _(sql).must_equal "SELECT * FROM users WHERE id IN (?, ?)"
      _(params).must_equal [1, 2]
      _(q.materialize.size).must_equal 2
    end

    it "translates id.in(1, 2) to the same SELECT ... WHERE id IN (?, ?)" do
      q = Users.where { id.in(1, 2) }
      sql, params = Diamond::Compiler::Base.compile(q.table, q.ast)
      _(sql).must_equal "SELECT * FROM users WHERE id IN (?, ?)"
      _(params).must_equal [1, 2]
    end

    it "produces identical compiled SQL for both IN forms" do
      a = Users.where { id == [1, 2] }
      b = Users.where { id.in(1, 2) }
      sql_a, params_a = Diamond::Compiler::Base.compile(a.table, a.ast)
      sql_b, params_b = Diamond::Compiler::Base.compile(b.table, b.ast)
      _(sql_a).must_equal sql_b
      _(params_a).must_equal params_b
    end

    it "supports string-literal IN values" do
      q = Users.where { name == ["Arle", "Carbuncle"] }
      sql, params = Diamond::Compiler::Base.compile(q.table, q.ast)
      _(sql).must_equal "SELECT * FROM users WHERE name IN (?, ?)"
      _(params).must_equal ["Arle", "Carbuncle"]
    end

    it "emits 1=0 for an empty array overload" do
      q = Users.where { id == [] }
      sql, params = Diamond::Compiler::Base.compile(q.table, q.ast)
      _(sql).must_equal "SELECT * FROM users WHERE 1=0"
      _(params).must_equal []
      _(q.materialize).must_be_empty
    end

    it "emits 1=0 for an empty explicit .in() call" do
      q = Users.where { id.in() }
      sql, _ = Diamond::Compiler::Base.compile(q.table, q.ast)
      _(sql).must_equal "SELECT * FROM users WHERE 1=0"
    end

    it "supports a single-element IN" do
      q = Users.where { id.in(5) }
      sql, params = Diamond::Compiler::Base.compile(q.table, q.ast)
      _(sql).must_equal "SELECT * FROM users WHERE id IN (?)"
      _(params).must_equal [5]
    end

    it "expands five-value IN into five placeholders" do
      q = Users.where { id.in(1, 2, 3, 4, 5) }
      sql, params = Diamond::Compiler::Base.compile(q.table, q.ast)
      _(sql).must_equal "SELECT * FROM users WHERE id IN (?, ?, ?, ?, ?)"
      _(params).must_equal [1, 2, 3, 4, 5]
    end

    it "chains IN with other WHERE conditions" do
      q = Users.where { id.in(1, 2) }
      q = q.where { name == "Arle" }
      sql, params = Diamond::Compiler::Base.compile(q.table, q.ast)
      _(sql).must_equal "SELECT * FROM users WHERE id IN (?, ?) AND name = ?"
      _(params).must_equal [1, 2, "Arle"]
    end

    it "accepts a column reference inside the IN array" do
      q = Users.where { id == [id] }
      sql, params = Diamond::Compiler::Base.compile(q.table, q.ast)
      _(sql).must_equal "SELECT * FROM users WHERE id IN (id)"
      _(params).must_equal []
      _(q.materialize.size).must_equal 4, "id IN (id) is tautologically true"
    end

    it "translates id != [1, 2] to NOT IN" do
      q = Users.where { id != [1, 2] }
      sql, params = Diamond::Compiler::Base.compile(q.table, q.ast)
      _(sql).must_equal "SELECT * FROM users WHERE id NOT IN (?, ?)"
      _(params).must_equal [1, 2]
      _(q.materialize.size).must_equal 2, "3 of 4 rows excluded"
    end

    it "emits 1=1 for an empty NOT IN array" do
      q = Users.where { id != [] }
      sql, params = Diamond::Compiler::Base.compile(q.table, q.ast)
      _(sql).must_equal "SELECT * FROM users WHERE 1=1"
      _(params).must_equal []
      _(q.materialize.size).must_equal 4, "NOT IN () is tautologically true"
    end

    it "keeps scalar id != 5 as NotEqual (no array overload)" do
      q = Users.where { id != 5 }
      sql, params = Diamond::Compiler::Base.compile(q.table, q.ast)
      _(sql).must_equal "SELECT * FROM users WHERE id <> ?"
      _(params).must_equal [5]
    end
  end

  # ====================================================================
  describe "::find" do
    it "builds a lazy Where AST" do
      q = Users.find(1)
      _(q).must_be_kind_of Diamond::QueryObject
      _(q.ast.first).must_be_kind_of Diamond::AST::Where
      _(q.ast.first.condition.left.name).must_equal :id
      _(q.ast.first.condition.right.value).must_equal 1
    end

    it "is lazy until attribute access" do
      _(Users.find(1).name).must_equal "Arle"
    end

    it "raises RecordNotFound for missing ids" do
      _(proc { Users.find(99999).name }).must_raise Diamond::RecordNotFound
    end
  end

  # ====================================================================
  describe "DDL — FK actions & indexes" do
    it "emits ON DELETE CASCADE when on_delete: :cascade is given" do
      ast = Diamond._build_relation(:widgets) do |t|
        t.attribute :id, Integer, primary_key: true, nullable: false
        t.attribute :owner_id, Integer
        t.foreign_key :owner_id, :owners, on_delete: :cascade
      end
      sql, _ = Diamond::Compiler::DDL.compile(ast)
      _(sql).must_match(/ON DELETE CASCADE/)
    end

    it "emits ON UPDATE SET NULL when on_update: :set_null is given" do
      ast = Diamond._build_relation(:widgets) do |t|
        t.attribute :id, Integer, primary_key: true, nullable: false
        t.attribute :owner_id, Integer
        t.foreign_key :owner_id, :owners, on_update: :set_null
      end
      sql, _ = Diamond::Compiler::DDL.compile(ast)
      _(sql).must_match(/ON UPDATE SET NULL/)
    end

    it "omits ON clauses when no action kwargs are given" do
      ast = Diamond._build_relation(:widgets) do |t|
        t.attribute :id, Integer, primary_key: true, nullable: false
        t.attribute :owner_id, Integer
        t.foreign_key :owner_id, :owners
      end
      sql, _ = Diamond::Compiler::DDL.compile(ast)
      _(sql).wont_match(/ON (DELETE|UPDATE)/)
    end

    it "raises ArgumentError on unknown on_delete action" do
      err = assert_raises(ArgumentError) do
        Diamond._build_relation(:widgets) do |t|
          t.attribute :id, Integer, primary_key: true, nullable: false
          t.attribute :owner_id, Integer
          t.foreign_key :owner_id, :owners, on_delete: :bogus
        end
      end
      _(err.message).must_match(/unknown on_delete/)
    end

    it "creates a UNIQUE index inline via t.index" do
      Diamond.define_relation(:widgets) do |t|
        t.attribute :id, Integer, primary_key: true, nullable: false
        t.attribute :name, String
        t.index :name, unique: true, name: :idx_widgets_name
      end
      rows = Diamond.engine.db.execute("PRAGMA index_list(widgets)")
      _(rows.map { |r| r['name'] }).must_include 'idx_widgets_name'
      row = rows.find { |r| r['name'] == 'idx_widgets_name' }
      _(row['unique']).must_equal 1
    end

    it "creates a non-unique index inline via t.index" do
      Diamond.define_relation(:widgets2) do |t|
        t.attribute :id, Integer, primary_key: true, nullable: false
        t.attribute :a, Integer
        t.attribute :b, Integer
        t.index :a, :b, name: :idx_w2_ab
      end
      row = Diamond.engine.db.execute("PRAGMA index_list(widgets2)").find { |r| r['name'] == 'idx_w2_ab' }
      _(row).must_be_kind_of Hash
      _(row['unique']).must_equal 0
    end

    it "creates an index via top-level Diamond.create_index" do
      Diamond.define_relation(:widgets3) do |t|
        t.attribute :id, Integer, primary_key: true, nullable: false
        t.attribute :a, Integer
      end
      Diamond.create_index :widgets3, [:a], unique: true, name: :idx_w3_a
      row = Diamond.engine.db.execute("PRAGMA index_list(widgets3)").find { |r| r['name'] == 'idx_w3_a' }
      _(row).must_be_kind_of Hash
      _(row['unique']).must_equal 1
    end

    it "rejects Diamond.create_index without a name kwarg" do
      Diamond.define_relation(:widgets4) do |t|
        t.attribute :id, Integer, primary_key: true, nullable: false
      end
      _(proc { Diamond.create_index :widgets4, [:id] }).must_raise ArgumentError
    end

    it "auto-enables PRAGMA foreign_keys = ON after wake_up" do
      Diamond.wake_up(':memory:')
      row = Diamond.engine.db.execute('PRAGMA foreign_keys').first
      _(row.values.first).must_equal 1
    end
  end

  # ====================================================================
  describe "::join" do
    it "auto-resolves via FK cache" do
      q = Users.join(:posts)
      _(q.ast.first).must_be_kind_of Diamond::AST::Join
      _(q.ast.first.type).must_equal :inner
      _(q.ast.first.on).must_equal({ user_id: :id })
      sql, _ = Diamond::Compiler::Base.compile(q.table, q.ast)
      _(sql).must_equal "SELECT * FROM users INNER JOIN posts ON posts.user_id = users.id"
    end

    it "honors explicit on: and type:" do
      q = Users.join(:posts, on: { id: :user_id }, type: :left)
      sql, _ = Diamond::Compiler::Base.compile(q.table, q.ast)
      _(sql).must_equal "SELECT * FROM users LEFT OUTER JOIN posts ON posts.id = users.user_id"
    end

    it "raises TableNotFound when no FK connects" do
      err = assert_raises(Diamond::TableNotFound) { Users.join(:categories) }
      _(err.message).must_match(/No foreign key connects/)
    end
  end

  # ====================================================================
  describe "::derive" do
    it "translates count(id) to SELECT COUNT(id)" do
      q = Users.derive { count(id) }
      sql, params = Diamond::Compiler::Base.compile(q.table, q.ast)
      _(sql).must_equal "SELECT COUNT(id) FROM users"
      _(params).must_equal []
    end

    it "supports bare columns" do
      q = Users.find(1).derive { name }
      sql, params = Diamond::Compiler::Base.compile(q.table, q.ast)
      _(sql).must_equal "SELECT name FROM users WHERE id = ?"
      _(params).must_equal [1]
    end
  end

  # ====================================================================
  describe "::create" do
    it "returns a frozen Struct with the new id" do
      u = Users.create(name: "Lemres", age: 30)
      _(u).must_be_kind_of Struct
      _(u.frozen?).must_equal true
      _(u.id).must_equal 5
      _(u.name).must_equal "Lemres"
      _(u.age).must_equal 30
      _(Users.find(5).first.name).must_equal "Lemres"
    end
  end

  # ====================================================================
  describe "::update" do
    it "supports the bareword block form" do
      _(Users.where { id == 1 }.update { age 17 }).must_equal 1
      _(Users.find(1).first.age).must_equal 17
    end

    it "updates multiple columns in one block" do
      Users.where { id == 2 }.update { age 200; name "Carby" }
      _(Users.find(2).first.age).must_equal 200
      _(Users.find(2).first.name).must_equal "Carby"
    end

    it "supports the assignment block form" do
      count = Users.where { id == 3 }.update { age = 26; age }
      _(count).must_equal 1
      _(Users.find(3).first.age).must_equal 26
    end

    it "affects all rows when no WHERE clause" do
      Users.update { age 0 }
      ages = Diamond::QueryObject.new(Users).materialize.map(&:age)
      _(ages).must_equal [0, 0, 0, 0]
    end

    it "raises UnknownColumnError for typos with DidYouMean" do
      err = assert_raises(Diamond::UnknownColumnError) { Users.where { id == 1 }.update { agi 99 } }
      _(err.message).must_match(/Did you mean 'age'\?/)
    end
  end

  describe "::delete" do
    it "removes rows matching WHERE" do
      Diamond.engine.db.execute("INSERT INTO users (id, name, age) VALUES (100, 'Bot1', 5)")
      Diamond.engine.db.execute("INSERT INTO users (id, name, age) VALUES (101, 'Bot2', 6)")
      _(Users.where { age < 10 }.delete).must_equal 2
      _(Users.where { age < 10 }.materialize).must_be_empty
    end

    it "removes all rows when no WHERE clause" do
      Users.delete
      _(Diamond::QueryObject.new(Users).materialize).must_be_empty
    end
  end

  describe "cache invalidation" do
    it "drops the cached result on self-update" do
      q = Users.where { age > 10 }
      q.materialize
      refute_nil(q.instance_variable_get(:@cached_result))
      q.update { age 99 }
      _(q.instance_variable_get(:@cached_result)).must_be_nil
      _(q.materialize.first.age).must_equal 99
    end
  end

  # ====================================================================
  describe "Diamond.with (CTE)" do
    it "returns a QueryObject that materializes through the CTE" do
      active = Users.where { age > 10 }
      q = Diamond.with(active: active) { |d| d.from(:active) }
      _(q).must_be_kind_of Diamond::QueryObject
      _(q.materialize.size).must_equal 4
    end

    it "interleaves CTE and main-query params" do
      cte_q = Diamond.with(over10: Users.where { age > 10 }) do |d|
        d.from(:over10).where { name == "Arle" }
      end
      cte_q.instance_variable_set(:@cached_result, nil)
      sql, params = Diamond::Compiler::Base.compile(cte_q.table, cte_q.ast)
      _(sql).must_equal "WITH over10 AS (SELECT * FROM users WHERE age > ?) SELECT * FROM over10 WHERE name = ?"
      _(params).must_equal [10, "Arle"]
    end
  end

  describe "Diamond.with_recursive" do
    it "compiles a RECURSIVE CTE with UNION ALL" do
      base = Categories.where { parent_id == nil }
      recursive = Categories.from_cte(:tree)
      recursive_q = Diamond.with_recursive(:tree, base, recursive)
      recursive_q.instance_variable_set(:@cached_result, nil)
      sql, params = Diamond::Compiler::Base.compile(recursive_q.table, recursive_q.ast)
      expected = "WITH RECURSIVE tree AS (SELECT * FROM categories WHERE parent_id = ? UNION ALL SELECT * FROM tree) SELECT * FROM tree"
      _(sql).must_equal expected
      _(params).must_equal [nil]
    end
  end

  # ====================================================================
  describe "Window Functions" do
    it "translates row_number.over(partition_by:, order:)" do
      q = Users.derive { row_number.over(partition_by: :age, order: :id) }
      sql, _ = Diamond::Compiler::Base.compile(q.table, q.ast)
      _(sql).must_equal "SELECT ROW_NUMBER() OVER (PARTITION BY age ORDER BY id) FROM users"
    end

    it "translates row_number.over(order:) without partition" do
      q = Users.derive { row_number.over(order: :id) }
      sql, _ = Diamond::Compiler::Base.compile(q.table, q.ast)
      _(sql).must_equal "SELECT ROW_NUMBER() OVER (ORDER BY id) FROM users"
    end
  end

  # ====================================================================
  describe "Multi-Statement Derive" do
    it "compiles count(id); max(age); min(age) into one SELECT" do
      q = Users.derive { count(id); max(age); min(age) }
      sql, _ = Diamond::Compiler::Base.compile(q.table, q.ast)
      _(sql).must_equal "SELECT COUNT(id), MAX(age), MIN(age) FROM users"
      row = q.first
      _(row).must_respond_to :count_id
      _(row).must_respond_to :max_age
      _(row).must_respond_to :min_age
      _(row.count_id).must_equal 4
      _(row.max_age).must_equal 250
      _(row.min_age).must_equal 16
    end

    it "supports bare column multi-statement" do
      q = Users.find(1).derive { id; name }
      sql, params = Diamond::Compiler::Base.compile(q.table, q.ast)
      _(sql).must_equal "SELECT id, name FROM users WHERE id = ?"
      _(params).must_equal [1]
      row = q.first
      _(row.id).must_equal 1
      _(row.name).must_equal "Arle"
      _(row).wont_respond_to :age
    end

    it "supports mixed multi-statement derive" do
      q = Users.find(1).derive { id; count(age) }
      row = q.first
      _(row.id).must_equal 1
      _(row.count_age).must_equal 1
    end
  end

  # ====================================================================
  describe "Dynamic Finders (by_*)" do
    it "returns a lazy QueryObject for a single column" do
      q = Users.by_name("Arle")
      _(q).must_be_kind_of Diamond::QueryObject
      _(q.ast.first).must_be_kind_of Diamond::AST::Where
      results = q.materialize
      _(results.size).must_equal 1
      _(results.first.name).must_equal "Arle"
    end

    it "chains multiple columns with AND" do
      q = Users.by_name_and_age("Arle", 16)
      _(q.materialize.size).must_equal 1
      _(q.first.name).must_equal "Arle"
    end

    it "raises UnknownColumnError with DidYouMean for typos" do
      err = assert_raises(Diamond::UnknownColumnError) { Users.by_naem("Arle") }
      _(err.message).must_match(/Did you mean 'name'\?/)
    end

    it "composes with derive" do
      results = Users.by_name("Arle").derive(:age).materialize
      _(results.size).must_equal 1
      _(results.first.age).must_equal 16
    end

    it "raises ArgumentError when no columns after by_ prefix" do
      _(proc { Users.by_ }).must_raise ArgumentError
    end

    it "raises ArgumentError on arity mismatch" do
      _(proc { Users.by_name }).must_raise ArgumentError
      _(proc { Users.by_name("a", "b") }).must_raise ArgumentError
    end

    it "works on QueryObject for progressive composition" do
      q = Users.where { age > 10 }.by_name("Arle")
      _(q.materialize.size).must_equal 1
      _(q.first.age).must_equal 16
    end

    it "responds to by_*-prefixed methods" do
      _(Users.respond_to?(:by_name)).must_equal true
      _(Users.respond_to?(:by_name_and_age)).must_equal true
      _(Users.respond_to?(:nonexistent_method)).must_equal false
    end
  end

  # ====================================================================
  describe "order / limit / offset" do
    it "chains order + limit + offset into a single SQL clause" do
      q = Users.where { age > 10 }.order(:name, age: :desc).limit(5).offset(2)
      _(q).must_be_kind_of Diamond::QueryObject
      sql, params = Diamond::Compiler::Base.compile(q.table, q.ast)
      _(sql).must_equal "SELECT * FROM users WHERE age > ? ORDER BY name ASC, age DESC LIMIT 5 OFFSET 2"
      _(params).must_equal [10]
    end

    it "defaults order directions to ASC for plain symbols" do
      q = Users.order(:name)
      sql, _ = Diamond::Compiler::Base.compile(q.table, q.ast)
      _(sql).must_equal "SELECT * FROM users ORDER BY name ASC"
    end

    it "honors a kwargs-only order hash" do
      q = Users.order(name: :asc, age: :desc)
      sql, _ = Diamond::Compiler::Base.compile(q.table, q.ast)
      _(sql).must_equal "SELECT * FROM users ORDER BY name ASC, age DESC"
    end

    it "rejects unknown order directions" do
      _(proc { Users.order(name: :sideways) }).must_raise ArgumentError
    end

    it "rejects unknown columns in symbol form" do
      err = assert_raises(Diamond::UnknownColumnError) { Users.order(:naem) }
      _(err.message).must_match(/Did you mean 'name'\?/)
    end

    it "rejects unknown columns in kwargs form" do
      _(proc { Users.order(bad: :asc) }).must_raise Diamond::UnknownColumnError
    end

    it "builds an AST::Limit on limit()" do
      q = Users.limit(5)
      _(q.ast.first).must_be_kind_of Diamond::AST::Limit
      _(q.ast.first.value).must_equal 5
    end

    it "builds an AST::Offset on offset()" do
      q = Users.offset(2)
      _(q.ast.first).must_be_kind_of Diamond::AST::Offset
      _(q.ast.first.value).must_equal 2
    end

    it "rejects non-Integer limit arguments" do
      _(proc { Users.limit("five") }).must_raise ArgumentError
    end

    it "rejects negative limit" do
      _(proc { Users.limit(-1) }).must_raise ArgumentError
    end

    it "rejects negative offset" do
      _(proc { Users.offset(-5) }).must_raise ArgumentError
    end

    it "uses last-wins semantics for chained Limit" do
      q = Users.limit(5).limit(10)
      _(q.ast.select { |n| n.is_a?(Diamond::AST::Limit) }.size).must_equal 1
      _(q.ast.find { |n| n.is_a?(Diamond::AST::Limit) }.value).must_equal 10
    end

    it "combines specs for chained Order" do
      q = Users.order(:name).order(:age)
      _(q.ast.select { |n| n.is_a?(Diamond::AST::Order) }.size).must_equal 1
      _(q.ast.find { |n| n.is_a?(Diamond::AST::Order) }.specs).must_equal [[:name, :asc], [:age, :asc]]
    end

    it "raises when derive() is chained twice on the same query" do
      _(proc { Users.derive(:name).derive(:age) }).must_raise RuntimeError
    end
  end

  # ====================================================================
  describe "pluck / exists? / count / first / last" do
    it "pluck(:name) returns a flat array" do
      _(Users.pluck(:name)).must_equal ["Arle", "Carbuncle", "Sig", "High"]
    end

    it "pluck(:name) with where filters the values" do
      _(Users.where { age > 100 }.pluck(:name)).must_equal ["High"]
    end

    it "pluck with multiple columns returns an array of arrays" do
      _(Users.pluck(:name, :age)).must_equal [["Arle", 16], ["Carbuncle", 100], ["Sig", 25], ["High", 250]]
    end

    it "pluck with unknown column raises DidYouMean" do
      err = assert_raises(Diamond::UnknownColumnError) { Users.pluck(:naem) }
      _(err.message).must_match(/Did you mean 'name'\?/)
    end

    it "pluck composes with where" do
      _(Users.where { age > 100 }.pluck(:name)).must_equal ["High"]
    end

    it "exists? returns true when matching rows exist" do
      _(Users.where { age > 100 }.exists?).must_equal true
    end

    it "exists? returns false when no rows match" do
      _(Users.where { age > 999 }.exists?).must_equal false
    end

    it "count returns the total row count" do
      _(Users.count).must_equal 4
    end

    it "count with where returns the filtered count" do
      _(Users.where { age > 100 }.count).must_equal 1
      _(Users.where { age > 1000 }.count).must_equal 0
    end

    it "first returns a single Struct for the lowest id" do
      first = Users.first
      _(first).must_be_kind_of Struct
      _(first.id).must_equal 1
      _(first.name).must_equal "Arle"
    end

    it "first(2) returns an Array of two Structs" do
      first_two = Users.first(2)
      _(first_two).must_be_kind_of Array
      _(first_two.size).must_equal 2
      _(first_two.map(&:id)).must_equal [1, 2]
    end

    it "first(1) returns a single Struct" do
      _(Users.first(1)).must_be_kind_of Struct
    end

    it "first with where returns a filtered Struct" do
      first = Users.where { age > 100 }.first
      _(first).must_be_kind_of Struct
      _(first.name).must_equal "High"
    end

    it "first respects an explicit order" do
      first = Users.order(:age).first
      _(first.name).must_equal "Arle"
    end

    it "last returns a single Struct for the highest id" do
      last = Users.last
      _(last).must_be_kind_of Struct
      _(last.id).must_equal 4
      _(last.name).must_equal "High"
    end

    it "last(2) returns an Array in ascending id order (reversed)" do
      last_two = Users.last(2)
      _(last_two).must_be_kind_of Array
      _(last_two.size).must_equal 2
      _(last_two.map(&:id)).must_equal [3, 4]
    end

    it "last with where returns the highest-id matching row" do
      last = Users.where { age > 10 }.last
      _(last.name).must_equal "High"
    end
  end

  # ====================================================================
  describe "Streaming edge — QueryObject#each (Cursor)" do
    it "yields frozen Structs when called with a block" do
      yielded = []
      Users.where { age > 10 }.each { |u| yielded << u }
      _(yielded.size).must_equal 4
      yielded.each do |u|
        _(u).must_be_kind_of Struct
        _(u.frozen?).must_equal true
      end
    end

    it "returns a Cursor that includes Enumerable when called without a block" do
      cursor = Users.where { age > 10 }.each
      _(cursor).must_be_kind_of Diamond::Cursor
      _(cursor.is_a?(Enumerable)).must_equal true
    end

    it "supports first(n) on the returned Cursor" do
      collected = Users.where { age > 10 }.each.first(3)
      _(collected.size).must_equal 3
      collected.each { |u| _(u).must_be_kind_of Struct }
    end

    it "supports Enumerable#lazy chain composition" do
      collected = Users.each.lazy.select { |u| u.age > 50 }.first(2)
      _(collected.size).must_equal 2
      names = collected.map(&:name)
      _(names).must_include 'High'
      _(names).must_include 'Carbuncle'
    end

    it "yields nothing for an empty result set" do
      yielded = []
      Users.where { age > 999 }.each { |u| yielded << u }
      _(yielded).must_be_empty
    end

    it "re-executes the query on each call (no caching)" do
      first_size = Users.each.to_a.size
      Diamond.engine.db.execute("INSERT INTO users (id, name, age) VALUES (99, 'Late', 7)")
      second_size = Users.each.to_a.size
      _(first_size).must_equal 4
      _(second_size).must_equal 5
    end

    it "is available on Table directly via the DSL" do
      yielded = []
      Users.each { |u| yielded << u.id }
      _(yielded).must_equal [1, 2, 3, 4]
    end

    it "closes the underlying statement via ensure after iteration" do
      # After a complete iteration, the SQLite statement is closed. If a
      # follow-up query works, the close was clean (no leaking handle).
      collected = Users.each.first(2)
      _(collected.size).must_equal 2
      # Independent query on same engine — proves the cursor handled cleanup:
      follow_up = Users.count
      _(follow_up).must_equal 4
    end
  end

  # ====================================================================
  describe "Hardening" do
    it "leaves the connection usable after a failed materialize" do
      Diamond.define_relation(:ephemeral) do |t|
        t.attribute :id, Integer, primary_key: true, nullable: false
      end
      q = Ephemeral.where { id == 1 }
      Diamond.engine.db.execute("DROP TABLE ephemeral")
      _(proc { q.materialize }).must_raise SQLite3::SQLException
      _(Users.count).must_equal 4
    end

    it "rejects malicious identifiers and quotes embedded quotes" do
      _(proc { Diamond.validate_ident!('users; DROP TABLE users;--', "table name") }).must_raise ArgumentError
      _(proc { Diamond.validate_ident!('has space', "column name") }).must_raise ArgumentError
      _(Diamond.quote_ident('a"b')).must_equal '"a""b"'
    end

    it "does not grow the ancestor chain on repeated wake_up" do
      before = Diamond::Table.ancestors.count(Diamond::DSL::Default)
      Diamond.wake_up(':memory:')
      after = Diamond::Table.ancestors.count(Diamond::DSL::Default)
      _(before).must_equal 1
      _(after).must_equal 1
    end

    it "does not collide struct cache keys across member splits" do
      col = ->(sym) { Diamond::AST::Column.new(sym) }
      s1 = Diamond::StructFactory.create(Users, { 'a_b' => 1, 'c' => 2 }, [col.(:a_b), col.(:c)])
      s2 = Diamond::StructFactory.create(Users, { 'a' => 1, 'b_c' => 2 }, [col.(:a), col.(:b_c)])
      _(s1.members).must_equal [:a_b, :c]
      _(s2.members).must_equal [:a, :b_c]
      _(s1.a_b).must_equal 1
      _(s2.b_c).must_equal 2
    end

    it "rebinds table constants to the new engine on re-wake" do
      _(Users.name).must_equal :users
      Diamond.wake_up(':memory:')
      _(Object.const_defined?(:Users, false)).must_equal false
      Diamond.define_relation(:users) do |t|
        t.attribute :id, Integer, primary_key: true, nullable: false
        t.attribute :nick, String
      end
      _(Users.schema[:columns]).must_equal [:id, :nick]
    end

    it "raises NameError for tables missing after re-wake" do
      _(Users.name).must_equal :users
      Diamond.wake_up(':memory:')
      _(proc { Users }).must_raise NameError
    end
  end

  # ====================================================================
  describe "Chunked IN, inline LIMIT/OFFSET, PK-less terminal errors" do
    it "chunks a 1200-element IN list into grouped OR predicates" do
      lits = (1..1200).map { |i| Diamond::AST::Literal.new(i) }
      cond = Diamond::AST::In.new(Diamond::AST::Column.new(:id), lits)
      q = Diamond::QueryObject.new(Users, [Diamond::AST::Where.new(cond)])
      sql, params = Diamond::Compiler::Base.compile(q.table, q.ast)
      _(sql.scan(" OR ").size).must_equal 2
      _(params.size).must_equal 1200
      _(q.materialize.size).must_equal 4
    end

    it "chunks a 600-element NOT IN list with AND" do
      lits = (1..600).map { |i| Diamond::AST::Literal.new(i) }
      cond = Diamond::AST::NotIn.new(Diamond::AST::Column.new(:id), lits)
      q = Diamond::QueryObject.new(Users, [Diamond::AST::Where.new(cond)])
      sql, params = Diamond::Compiler::Base.compile(q.table, q.ast)
      _(sql).must_match(/NOT IN/)
      _(sql.scan(" AND ").size).must_equal 1
      _(params.size).must_equal 600
      _(q.materialize.size).must_equal 0
    end

    it "inlines LIMIT/OFFSET as literals, not bound params" do
      q = Users.limit(3).offset(1)
      sql, params = Diamond::Compiler::Base.compile(q.table, q.ast)
      _(sql).must_match(/LIMIT 3/)
      _(sql).must_match(/OFFSET 1/)
      _(params).must_equal []
      _(q.materialize.size).must_equal 3
    end

    it "raises a clear column error for terminals on PK-less tables without id" do
      Diamond.define_relation(:kv) do |t|
        t.attribute :k, String
        t.attribute :v, String
      end
      err = assert_raises(Diamond::UnknownColumnError) { Kv.first }
      _(err.message).must_match(/has no column/)
      _(proc { Kv.count }).must_raise Diamond::UnknownColumnError
      _(proc { Kv.where { k == "a" }.exists? }).must_raise Diamond::UnknownColumnError
    end
  end

  # ====================================================================
  # Static parsing invariants
  describe "Static parsing invariants" do
    it "has zero instance_eval calls in lib/" do
      offenders = Dir["lib/**/*.rb"].flat_map do |f|
        File.readlines(f).select { |line| line.include?("instance_eval") }
      end
      _(offenders).must_be_empty
    end

    it "has zero BasicObject subclasses in lib/" do
      offenders = Dir["lib/**/*.rb"].flat_map do |f|
        File.readlines(f).select { |line| line.include?("BasicObject") }
      end
      _(offenders).must_be_empty
    end

    it "caches where-block translations for repeated invocations" do
      Users.where { age > 10 }
      cache = Diamond::Parser.instance_variable_get(:@where_cache)
      _(cache).wont_be_empty
    end
  end
end

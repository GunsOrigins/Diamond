module Diamond
  module AST
    class Node
      # Logical operators must be on the base Node so any two conditions can be joined
      def &(other)
        AST::And.new(self, other)
      end

      def |(other)
        AST::Or.new(self, other)
      end
    end

    class Column < Node
      attr_reader :name
      def initialize(name); @name = name; end

      def ==(other)
        AST::Equality.new(self, AST::Literal.new(other))
      end

      def !=(other)
        AST::NotEqual.new(self, AST::Literal.new(other))
      end

      def >(other)
        AST::GreaterThan.new(self, AST::Literal.new(other))
      end

      def <(other)
        AST::LessThan.new(self, AST::Literal.new(other))
      end
    end

    class Literal < Node
      attr_reader :value
      def initialize(value); @value = value; end
    end

    class BinaryOp < Node
      attr_reader :left, :right, :operator
      def initialize(left, right, operator)
        @left = left; @right = right; @operator = operator
      end
    end

    class Equality < BinaryOp
      def initialize(left, right); super(left, right, :'='); end
    end

    class NotEqual < BinaryOp
      def initialize(left, right); super(left, right, :'<>'); end
    end

    # `WHERE col IN (v1, v2, v3)`. `left` is typically an AST::Column;
    # `right` is an Array of AST nodes (usually AST::Literal, but
    # expressions are allowed too).
    class In < Node
      attr_reader :left, :right
      def initialize(left, right)
        @left = left
        @right = right
      end
    end

    # `WHERE col NOT IN (v1, v2, v3)`. Same shape as In; emitted as
    # `NOT IN` in SQL.
    class NotIn < Node
      attr_reader :left, :right
      def initialize(left, right)
        @left = left
        @right = right
      end
    end

    class GreaterThan < BinaryOp
      def initialize(left, right); super(left, right, :'>'); end
    end

    class LessThan < BinaryOp
      def initialize(left, right); super(left, right, :'<'); end
    end

    class And < BinaryOp
      def initialize(left, right); super(left, right, :AND); end
    end

    class Or < BinaryOp
      def initialize(left, right); super(left, right, :OR); end
    end

    class Where < Node
      attr_reader :condition
      def initialize(condition); @condition = condition; end
    end

    class Projection < Node
      attr_reader :columns
      def initialize(columns); @columns = columns; end
    end

    # Joins another table. `type` is :inner, :left, :right, :full.
    # `on` is a Hash mapping the LOCAL column (key) to the REFERENCED column (value),
    # e.g. { user_id: :id } — meaning "join ON <other>.user_id = <self>.id".
    class Join < Node
      attr_reader :table_name, :type, :on
      def initialize(table_name, type, on)
        @table_name = table_name
        @type = type
        @on = on
      end
    end

    # For CTEs (WITH clause)
    class With < Node
      attr_reader :name, :query, :recursive
      def initialize(name, query, recursive: false)
        @name = name
        @query = query
        @recursive = recursive
      end
    end

    # ORDER BY clause. `specs` is an Array of [column_sym, :asc|:desc] pairs.
    # Order/Limit/Offset come after WHERE in the emitted SQL.
    class Order < Node
      attr_reader :specs
      def initialize(specs)
        @specs = specs
      end
    end

    # LIMIT clause. Holds the limit integer.
    class Limit < Node
      attr_reader :value
      def initialize(value)
        @value = value
      end
    end

    # OFFSET clause. Holds the offset integer.
    class Offset < Node
      attr_reader :value
      def initialize(value)
        @value = value
      end
    end

    # To change the FROM target (for querying CTEs)
    class From < Node
      attr_reader :name
      def initialize(name); @name = name; end
    end

    # For SQL Functions (COUNT, SUM, AVG, etc.)
    class Function < Node
      attr_reader :name, :args
      def initialize(name, args)
        @name = name.to_s.upcase
        @args = args # Array of AST::Column or AST::Literal
      end
    end

    # For Window Functions
    class WindowFunction < Node
      attr_reader :func_name, :args, :partition_by, :order_by

      def initialize(func_name, args, partition_by: [], order_by: [])
        @func_name = func_name.to_s.upcase
        @args = args
        @partition_by = partition_by
        @order_by = order_by
      end
    end

    # For Recursive CTEs (UNION ALL)
    class Union < Node
      attr_reader :left, :right, :operator
      def initialize(left, right, operator = "UNION ALL")
        @left = left
        @right = right
        @operator = operator
      end
    end

    # --- DDL Nodes (Phase 1) ---

    # Top-level CREATE TABLE node. Holds the table name (Symbol)
    # and an ordered array of column definitions and foreign keys.
    class DefineRelation < Node
      attr_reader :name, :columns
      def initialize(name, columns)
        @name = name
        @columns = columns
      end
    end

    # A single column in a CREATE TABLE statement.
    # `type` is a Ruby class (Integer, String, Float, TrueClass, FalseClass).
    # `options` is a Hash; recognized keys: :primary_key, :nullable, :default.
    class ColumnDefinition < Node
      attr_reader :name, :type, :options
      def initialize(name, type, options = {})
        @name = name
        @type = type
        @options = options
      end
    end

    # Table-level FOREIGN KEY constraint referencing another table.
    # `on_delete` / `on_update` are one of: :cascade, :set_null,
    # :set_default, :restrict, :no_action. `nil` means no action clause
    # is emitted (DB default).
    class ForeignKey < Node
      attr_reader :local_column, :ref_table, :ref_column, :on_delete, :on_update
      def initialize(local_column, ref_table, ref_column = :id,
                     on_delete: nil, on_update: nil)
        @local_column = local_column
        @ref_table = ref_table
        @ref_column = ref_column
        @on_delete = on_delete
        @on_update = on_update
      end
    end

    # `CREATE [UNIQUE] INDEX name ON table(cols)`. Lifted into AST so
    # `define_relation` can emit CREATE TABLE then CREATE INDEX in one
    # transactional sweep.
    class IndexDefinition < Node
      attr_reader :name, :columns, :unique
      def initialize(name, columns, unique: false)
        @name = name
        @columns = columns
        @unique = unique
      end
    end

    # --- DML Nodes ---

    # INSERT INTO statement. `data` is a Hash mapping column name (Symbol) to value.
    class Insert < Node
      attr_reader :data
      def initialize(data)
        @data = data
      end
    end

    # UPDATE statement. `data` is a Hash mapping column name (Symbol) to value.
    class Update < Node
      attr_reader :data
      def initialize(data)
        @data = data
      end
    end

    # DELETE statement marker. The target rows are derived from the QueryObject's WHERE nodes.
    class Delete < Node
    end
  end
end
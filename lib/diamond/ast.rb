module Diamond
  module AST
    class Node
      # so you can `&` / `|` any two conditions together.
      def &(other)
        AST::And.new(self, other)
      end

      def |(other)
        AST::Or.new(self, other)
      end
    end

    # `table` is nil for plain `age`, or a table name for qualified
    # `tags.tag` refs in blocks over joins. qualified columns render with
    # their own table and ignore the eager parent-prefix.
    class Column < Node
      attr_reader :name, :table
      def initialize(name, table: nil); @name = name; @table = table; end

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

    # `right` may hold expressions, not just literals.
    class In < Node
      attr_reader :left, :right
      def initialize(left, right)
        @left = left
        @right = right
      end
    end

    class NotIn < Node
      attr_reader :left, :right
      def initialize(left, right)
        @left = left
        @right = right
      end
    end

    # Wraps a QueryObject as a SQL subquery: `(SELECT ...)`.
    class Subquery < Node
      attr_reader :query
      def initialize(query); @query = query; end
    end

    class GreaterThan < BinaryOp
      def initialize(left, right); super(left, right, :'>'); end
    end

    class LessThan < BinaryOp
      def initialize(left, right); super(left, right, :'<'); end
    end

    class GreaterEqual < BinaryOp
      def initialize(left, right); super(left, right, :'>='); end
    end

    class LessEqual < BinaryOp
      def initialize(left, right); super(left, right, :<=); end
    end

    # `!(cond)` and `not cond` are the same Prism shape. wraps anything;
    # sqlite truthiness applies to non-boolean operands.
    class Not < Node
      attr_reader :condition
      def initialize(condition); @condition = condition; end
    end

    class Like < BinaryOp
      def initialize(left, right); super(left, right, :LIKE); end
    end

    class IsNull < Node
      attr_reader :column
      def initialize(column); @column = column; end
    end

    class IsNotNull < Node
      attr_reader :column
      def initialize(column); @column = column; end
    end

    class Between < Node
      attr_reader :column, :low, :high
      def initialize(column, low, high)
        @column = column
        @low = low
        @high = high
      end
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

    # `on` maps LOCAL col to FOREIGN col, e.g. { user_id: :id }.
    # `eager: true` marks the join for object-graph transform: the SQL gets
    # column aliases (users.id AS users.id, posts.id AS posts.id, ...) and
    # the compiler returns an Extralite::Transform spec that deduplicates
    # and nests the rows.
    class Join < Node
      attr_reader :table_name, :type, :on, :eager
      def initialize(table_name, type, on, eager: false)
        @table_name = table_name
        @type = type
        @on = on
        @eager = eager
      end
    end

    class With < Node
      attr_reader :name, :query, :recursive
      def initialize(name, query, recursive: false)
        @name = name
        @query = query
        @recursive = recursive
      end
    end

    # `specs` is [[col, :asc|:desc], ...]. lands after WHERE in the sql.
    class Order < Node
      attr_reader :specs
      def initialize(specs)
        @specs = specs
      end
    end

    class Limit < Node
      attr_reader :value
      def initialize(value)
        @value = value
      end
    end

    class Offset < Node
      attr_reader :value
      def initialize(value)
        @value = value
      end
    end

    class GroupBy < Node
      attr_reader :columns
      def initialize(columns)
        @columns = columns # Array of Symbol column names
      end
    end

    class Having < Node
      attr_reader :condition
      def initialize(condition)
        @condition = condition
      end
    end

    # swap the FROM target (how you query a CTE).
    class From < Node
      attr_reader :name
      def initialize(name); @name = name; end
    end

    class Function < Node
      attr_reader :name, :args
      def initialize(name, args)
        @name = name.to_s.upcase
        @args = args # Array of AST::Column or AST::Literal
      end
    end

    class WindowFunction < Node
      attr_reader :func_name, :args, :partition_by, :order_by

      def initialize(func_name, args, partition_by: [], order_by: [])
        @func_name = func_name.to_s.upcase
        @args = args
        @partition_by = partition_by
        @order_by = order_by
      end
    end

    class Union < Node
      attr_reader :left, :right, :operator
      def initialize(left, right, operator = "UNION ALL")
        @left = left
        @right = right
        @operator = operator
      end
    end

    # --- DDL Nodes ---

    # column order is DDL order.
    class DefineRelation < Node
      attr_reader :name, :columns
      def initialize(name, columns)
        @name = name
        @columns = columns
      end
    end

    # `type` is a ruby class. `options` knows :primary_key, :nullable, :default.
    class ColumnDefinition < Node
      attr_reader :name, :type, :options
      def initialize(name, type, options = {})
        @name = name
        @type = type
        @options = options
      end
    end

    # on_delete/on_update: :cascade, :set_null, :set_default, :restrict,
    # :no_action. nil leaves the clause out.
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

    # lifted into the AST so define_relation does CREATE TABLE then
    # CREATE INDEX in one go.
    class IndexDefinition < Node
      attr_reader :name, :columns, :unique
      def initialize(name, columns, unique: false)
        @name = name
        @columns = columns
        @unique = unique
      end
    end

    # --- DML Nodes ---

    # `data`: Hash mapping column name (Symbol) to value.
    class Insert < Node
      attr_reader :data
      def initialize(data)
        @data = data
      end
    end

    # `data`: Hash mapping column name (Symbol) to value.
    class Update < Node
      attr_reader :data
      def initialize(data)
        @data = data
      end
    end

    # rows come from the chain's WHERE nodes.
    class Delete < Node
    end

    # indented tree dump for staring at what a block became. one line
    # per node, children indented two spaces. QueryObject#ast_tree maps
    # this over the chain.
    def self.dump(node, indent = 0)
      pad = '  ' * indent
      label = case node
              when Column
                node.table ? "Column(#{node.table}.#{node.name})" : "Column(#{node.name})"
              when Literal
                "Literal(#{node.value.inspect})"
              when BinaryOp
                node.class.name.split('::').last
              when In, NotIn
                "#{node.class.name.split('::').last}(#{node.right.size} vals)"
              when IsNull, IsNotNull
                node.class.name.split('::').last
              when Between
                'Between'
              when Not
                'Not'
              when Subquery
                'Subquery'
              when Function
                "#{node.name}(#{node.args.size} args)"
              when WindowFunction
                "#{node.func_name} OVER"
              when Where
                'Where'
              when Projection
                "Projection(#{node.columns.size} cols)"
              when Join
                "Join(#{node.table_name}, #{node.type}#{node.eager ? ', eager' : ''})"
              when Order
                "Order(#{node.specs.map { |c, d| "#{c} #{d}" }.join(', ')})"
              when Limit
                "Limit(#{node.value})"
              when Offset
                "Offset(#{node.value})"
              when GroupBy
                "GroupBy(#{node.columns.join(', ')})"
              when Having
                'Having'
              when From
                "From(#{node.name})"
              when With
                "With(#{node.name}#{node.recursive ? ', recursive' : ''})"
              when Union
                "Union(#{node.operator})"
              else
                node.class.name.split('::').last
              end
      lines = ["#{pad}#{label}"]
      kids = case node
             when BinaryOp then [node.left, node.right]
             when In, NotIn then [node.left] + (node.right.is_a?(Array) ? node.right : [node.right])
             when IsNull, IsNotNull then [node.column]
             when Between then [node.column, node.low, node.high]
             when Not then [node.condition]
             when Function then node.args
             when Where, Having then [node.condition]
             when Projection then node.columns
             when Union then [node.left, node.right]
             else []
             end
      kids.each do |k|
        lines << (k.is_a?(Node) ? dump(k, indent + 1) : "#{pad}  #{k.inspect}")
      end
      # With/Subquery hold whole queries — a Union node or a QueryObject
      # carrying a chain. dump whichever it is.
      if node.is_a?(With) || node.is_a?(Subquery)
        q = node.query
        if q.is_a?(Node)
          lines << dump(q, indent + 1)
        else
          q.ast.each { |n| lines << dump(n, indent + 1) }
        end
      end
      lines.join("\n")
    end
  end
end
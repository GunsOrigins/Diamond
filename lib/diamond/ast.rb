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

    # For CTEs (WITH clause)
    class With < Node
      attr_reader :name, :query, :recursive
      def initialize(name, query, recursive: false)
        @name = name
        @query = query
        @recursive = recursive
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
  end
end
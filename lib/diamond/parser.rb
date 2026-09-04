require 'prism'

module Diamond
  module Parser
    WINDOW_FUNCS = [:row_number, :rank, :dense_rank, :lag, :lead].freeze
    AGGREGATIONS = [:count, :sum, :avg, :min, :max].freeze
    DDL_METHODS  = [:attribute, :primary_key, :foreign_key, :index].freeze

    @file_cache = {}
    @where_cache = {}
    @derive_cache = {}
    @ddl_cache = {}
    @update_cache = {}
    @line_cache = {}

    # ====================================================================
    # Where blocks (conditions): single-expression Prism translation.
    # Returns a single AST::Node.
    # ====================================================================
    def self.parse_block(block, schema)
      _parse_with_candidates(block, :where) { |node| translate_where(node, schema) }
    end

    # ====================================================================
    # Derive blocks (projections): multi-statement. Returns Array<AST node>.
    # Supports bare columns, function calls, and window function chains.
    # ====================================================================
    def self.parse_derive(block, schema)
      _parse_with_candidates(block, :derive) do |node|
        unwrap_statements(node).map { |stmt| translate_derive(stmt, schema) }
      end
    end

    # ====================================================================
    # DDL blocks (define_relation): multi-statement. Returns Array<ColumnDefinition|ForeignKey>.
    # ====================================================================
    def self.parse_ddl(block)
      _parse_with_candidates(block, :ddl) do |node|
        unwrap_statements(node).map { |stmt| translate_ddl_stmt(stmt) }
      end
    end

    # ====================================================================
    # Update blocks: multi-statement. Returns Hash{Symbol => value}.
    # Supports both `age 17` (CallNode) and `age = 17` (LocalVariableWriteNode).
    # ====================================================================
    def self.parse_update(block, schema)
      _parse_with_candidates(block, :update) do |node|
        statements = unwrap_statements(node)
        hash = {}
        statements.each do |stmt|
          case stmt
          when Prism::LocalVariableWriteNode
            validate_column!(stmt.name, schema)
            hash[stmt.name] = literal_value(stmt.value)
          when Prism::LocalVariableReadNode
            # Trailing read of an assigned local (e.g. `age = 26; age`).
            # Silences Ruby's "assigned but unused variable" warning at the
            # call site. We treat it as a no-op reference; the value is not
            # used to update any column.
            next
          when Prism::CallNode
            positional, kwargs = split_args(stmt)
            if stmt.receiver.nil? && positional.size == 1 && kwargs.empty?
              validate_column!(stmt.name, schema)
              hash[stmt.name] = literal_value(positional.first)
            else
              raise BlockMismatch, "Invalid update statement: #{stmt.inspect}"
            end
          else
            raise BlockMismatch, "Invalid update statement: #{stmt.class}"
          end
        end
        hash
      end
    end

    # ====================================================================
    # Internals
    # ====================================================================

    # Raised when a candidate BlockNode doesn't match the expected parser shape.
    # Distinct from validation errors (UnknownColumnError, etc.) which mean
    # "this IS the right block but the content is invalid".
    class BlockMismatch < StandardError; end

    def self.cache_for(purpose)
      case purpose
      when :where  then @where_cache
      when :derive then @derive_cache
      when :ddl    then @ddl_cache
      when :update then @update_cache
      end
    end

    # Memoized block discovery: the full-tree walk in locate_block_nodes is
    # O(file nodes) per call, so cache the candidate list per [file, line].
    # All four parse entry points share it — a line used as both `where`
    # and `derive` still walks only once.
    def self.candidate_blocks(file, line)
      key = [file, line]
      return @line_cache[key] if @line_cache.key?(key)
      @file_cache[file] ||= Prism.parse_file(file).value
      @line_cache[key] = locate_block_nodes(@file_cache[file], line)
    end

    # Canonical block-discovery helper. Walks a Prism AST and returns every
    # BlockNode starting on `line`. Used by every public parse method.
    def self.locate_block_nodes(node, line, results = [])
      return results unless node.respond_to?(:location)

      if node.is_a?(Prism::BlockNode) && node.location.start_line == line
        results << node
      end

      if node.compact_child_nodes
        node.compact_child_nodes.each do |child|
          locate_block_nodes(child, line, results)
        end
      end
      results
    end

    # Unified candidate-walker. For chained blocks on the same line (e.g.
    # `Users.where { ... }.update { ... }`), tries each candidate BlockNode
    # in source order and returns the first one the translator successfully
    # parses. Validation errors (UnknownColumnError, etc.) propagate so the
    # user sees the *real* problem with the right block.
    def self._parse_with_candidates(block, purpose, &translator)
      file, line = block.source_location
      raise "Cannot parse block without a file source" unless file

      cache = cache_for(purpose)
      cache_key = [file, line, purpose]
      return cache[cache_key] if cache.key?(cache_key)

      candidates = candidate_blocks(file, line)

      result = nil
      candidates.each do |candidate|
        begin
          result = translator.call(candidate)
          break
        rescue BlockMismatch
          next
        end
      end

      raise "No parseable #{purpose} block found at #{file}:#{line}" if result.nil?
      cache[cache_key] = result
    end

    # Dives through BlockNode/ParenthesesNode to get the inner StatementsNode.
    # Returns an Array of statement nodes.
    def self.unwrap_statements(block_node)
      body = block_node.body
      body = body.body if body.is_a?(Prism::ParenthesesNode)
      # body is now StatementsNode
      body.body.reject { |stmt| stmt.is_a?(Prism::ProgramNode) }
    end

    # ----- Where translation -----
    def self.translate_where(node, schema)
      case node
      when Prism::BlockNode
        translate_where(node.body, schema)
      when Prism::StatementsNode
        translate_where(node.body.first, schema)
      when Prism::ParenthesesNode
        translate_where(node.body, schema)
      when Prism::CallNode
          # Explicit `.in(1, 2, 3)` form — must be intercepted BEFORE the
          # binary-operator fallthrough because it's a multi-arg call.
          # Zero-arg `id.in()` is also handled here (node.arguments is nil).
          # Receivers must be set; bareword column access goes through the
          # no-receiver branch below.
          if node.name == :in && node.receiver
            lhs  = translate_where(node.receiver, schema)
            vals = node.arguments ? node.arguments.arguments.map { |a| translate_where(a, schema) } : []
            return AST::In.new(lhs, vals)
          end

          if node.name == :proc && node.block
            translate_where(node.block, schema)
          elsif node.receiver.nil? && node.arguments.nil?
            validate_column!(node.name, schema)
            AST::Column.new(node.name)
          elsif node.receiver && node.arguments

          left      = translate_where(node.receiver, schema)
          right_arg = node.arguments.arguments.first

          # Array overload: id == [1, 2, 3] → AST::In
          if node.name == :== && right_arg.is_a?(Prism::ArrayNode)
            vals = right_arg.elements.map { |e| translate_where(e, schema) }
            return AST::In.new(left, vals)
          end

          # Array overload: id != [1, 2, 3] → AST::NotIn
          if node.name == :"!=" && right_arg.is_a?(Prism::ArrayNode)
            vals = right_arg.elements.map { |e| translate_where(e, schema) }
            return AST::NotIn.new(left, vals)
          end

          right = translate_where(right_arg, schema)
          case node.name
          when :> then AST::GreaterThan.new(left, right)
          when :< then AST::LessThan.new(left, right)
          when :== then AST::Equality.new(left, right)
          when :"!=" then AST::NotEqual.new(left, right)
          when :&, :"&&" then AST::And.new(left, right)
          when :|, :"||" then AST::Or.new(left, right)
          else
            raise BlockMismatch, "Unsupported operator: #{node.name}"
          end
          else
            raise BlockMismatch, "Unsupported call: #{node.inspect}"
          end
      when Prism::AndNode
        AST::And.new(translate_where(node.left, schema), translate_where(node.right, schema))
      when Prism::OrNode
        AST::Or.new(translate_where(node.left, schema), translate_where(node.right, schema))
      when Prism::IntegerNode
        AST::Literal.new(node.value)
      when Prism::FloatNode
        AST::Literal.new(node.value)
      when Prism::StringNode
        AST::Literal.new(node.unescaped)
      when Prism::NilNode
        AST::Literal.new(nil)
      when Prism::TrueNode
        AST::Literal.new(true)
      when Prism::FalseNode
        AST::Literal.new(false)
      else
        raise BlockMismatch, "Unsupported Prism AST Node: #{node.class}"
      end
    end

    # ----- Derive translation -----
    def self.translate_derive(node, schema)
      case node
      when Prism::CallNode
        positional, kwargs = split_args(node)

        if node.receiver.nil? && positional.empty? && kwargs.empty?
          # Bareword column: `name`
          validate_column!(node.name, schema)
          return AST::Column.new(node.name)
        end

        if node.receiver.nil? && !positional.empty? && kwargs.empty?
          # Function call: `count(id)`, `sum(age)`
          args = positional.map { |a| translate_derive(a, schema) }
          return AST::Function.new(node.name, args)
        end

        if node.name == :over && node.receiver
          # Window function chain: `row_number.over(partition_by: :age, order: :id)`
          inner = node.receiver
          unless inner.is_a?(Prism::CallNode) && inner.receiver.nil? && inner.arguments.nil?
            raise BlockMismatch, "Window function receiver must be a bareword call: #{inner.inspect}"
          end
          unless WINDOW_FUNCS.include?(inner.name)
            raise BlockMismatch, "Not a window function: #{inner.name}"
          end
          # Reuse the split_args from the top of this branch (kwargs holds
          # the already-parsed keyword hash) instead of walking args twice.
          partition_by = Array(kwargs[:partition_by]).map(&:to_sym)
          order_by = Array(kwargs[:order]).map(&:to_sym)
          return AST::WindowFunction.new(inner.name, [], partition_by: partition_by, order_by: order_by)
        end

        raise BlockMismatch, "Unsupported derive call: #{node.inspect}"
      when Prism::SymbolNode
        validate_column!(node.value, schema)
        AST::Column.new(node.value)
      when Prism::IntegerNode
        AST::Literal.new(node.value)
      when Prism::FloatNode
        AST::Literal.new(node.value)
      when Prism::StringNode
        AST::Literal.new(node.unescaped)
      when Prism::NilNode
        AST::Literal.new(nil)
      when Prism::TrueNode
        AST::Literal.new(true)
      when Prism::FalseNode
        AST::Literal.new(false)
      else
        raise BlockMismatch, "Unsupported derive AST node: #{node.class}"
      end
    end

    # ----- DDL translation -----
    def self.translate_ddl_stmt(node)
      raise BlockMismatch, "DDL statement must be a method call, got #{node.class}" unless node.is_a?(Prism::CallNode)
      raise BlockMismatch, "Unknown DDL method: #{node.name}" unless DDL_METHODS.include?(node.name)

      positional, kwargs = split_args(node)

      case node.name
      when :attribute
        raise "attribute requires name and type" if positional.size < 2
        name = symbol_value(positional[0])
        type = translate_type(positional[1])
        AST::ColumnDefinition.new(name, type, kwargs)
      when :primary_key
        raise "primary_key requires a name argument" if positional.empty?
        name = symbol_value(positional[0])
        AST::ColumnDefinition.new(name, Integer, primary_key: true, nullable: false)
      when :foreign_key
        raise "foreign_key requires local column and ref table" if positional.size < 2
        local = symbol_value(positional[0])
        ref_table = symbol_value(positional[1])
        ref_col = positional[2] ? symbol_value(positional[2]) : :id

        on_delete = kwargs[:on_delete]
        on_update = kwargs[:on_update]
        valid_actions = %i[cascade set_null set_default restrict no_action]
        if on_delete
          on_delete = on_delete.to_sym
          unless valid_actions.include?(on_delete)
            raise ArgumentError, "unknown on_delete action: #{on_delete.inspect}; must be one of #{valid_actions.inspect}"
          end
        end
        if on_update
          on_update = on_update.to_sym
          unless valid_actions.include?(on_update)
            raise ArgumentError, "unknown on_update action: #{on_update.inspect}; must be one of #{valid_actions.inspect}"
          end
        end

        AST::ForeignKey.new(local, ref_table, ref_col,
                            on_delete: on_delete, on_update: on_update)
      when :index
        raise "index requires at least one column" if positional.empty?
        cols = positional.map { |a| symbol_value(a) }
        idx_name = kwargs[:name] || raise(ArgumentError, "index requires `name:` kwarg")
        unique = !!kwargs[:unique]
        AST::IndexDefinition.new(idx_name, cols, unique: unique)
      end
    end

    # ----- Shared helpers -----
    # Splits a CallNode's args into positional and keyword hashes.
    # Returns [positional_array, kwargs_hash].
    def self.split_args(call_node)
      return [[], {}] unless call_node.arguments

      positional = []
      kwargs = {}
      call_node.arguments.arguments.each do |arg|
        if arg.is_a?(Prism::KeywordHashNode)
          arg.elements.each do |assoc|
            key = kwarg_key(assoc.key)
            kwargs[key] = literal_value_or_array(assoc.value)
          end
        else
          positional << arg
        end
      end
      [positional, kwargs]
    end

    def self.kwarg_key(node)
      case node
      when Prism::SymbolNode then node.value.to_sym
      when Prism::StringNode then node.unescaped.to_sym
      else node.name.to_sym
      end
    end

    def self.symbol_value(node)
      raise "Expected SymbolNode, got #{node.class}" unless node.is_a?(Prism::SymbolNode)
      node.value
    end

    def self.translate_type(node)
      unless node.is_a?(Prism::ConstantReadNode)
        raise ArgumentError, "Type must be a constant (e.g., Integer, String)"
      end
      begin
        Object.const_get(node.name)
      rescue NameError
        type_spellcheck(node.name)
      end
    end

    def self.type_spellcheck(name)
      dictionary = Object.constants.map(&:to_s)
      suggestions = DidYouMean::SpellChecker.new(dictionary: dictionary).correct(name.to_s)
      msg = "Unknown type '#{name}'."
      msg += " Did you mean '#{suggestions.first}'?" unless suggestions.empty?
      raise ArgumentError, msg
    end

    def self.extract_keyword_hash(call_node)
      _, kwargs = split_args(call_node)
      kwargs
    end

    def self.literal_value_or_array(node)
      if node.is_a?(Prism::ArrayNode)
        node.elements.map { |e| literal_value(e) }
      else
        literal_value(node)
      end
    end

    def self.literal_value(node)
      case node
      when Prism::IntegerNode  then node.value
      when Prism::FloatNode    then node.value
      when Prism::StringNode   then node.unescaped
      when Prism::SymbolNode   then node.value
      when Prism::TrueNode     then true
      when Prism::FalseNode    then false
      when Prism::NilNode      then nil
      when Prism::ConstantReadNode
        begin
          Object.const_get(node.name)
        rescue NameError
          node.name
        end
      else
        raise "Not a literal value: #{node.class}"
      end
    end

    def self.validate_column!(name, schema)
      Diamond.validate_ident!(name, "column name")
      return if schema[:columns].empty?
      return if schema[:columns].include?(name)

      dictionary = schema[:columns].map(&:to_s)
      suggestions = DidYouMean::SpellChecker.new(dictionary: dictionary).correct(name.to_s)
      msg = "Table has no column '#{name}'."
      msg += " Did you mean '#{suggestions.first}'?" unless suggestions.empty?
      raise Diamond::UnknownColumnError, msg
    end
  end
end

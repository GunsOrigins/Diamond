require 'prism'

module Diamond
  module Parser
    WINDOW_FUNCS = [:row_number, :rank, :dense_rank, :lag, :lead].freeze
    AGGREGATIONS = [:count, :sum, :avg, :min, :max].freeze
    DDL_METHODS  = [:attribute, :primary_key, :foreign_key, :index].freeze

    # caches are per-Ractor so a worker Ractor doesn't trip an isolation
    # error trying to read main-Ractor Prism::Node values. each Ractor
    # keeps its own hash on Ractor.current's local storage, keyed by
    # purpose (:where, :derive, :ddl, :update, :line).
    CACHES_KEY = Diamond::RACTOR_KEYS[:parser_caches]

    def self.caches
      Ractor.current[CACHES_KEY] ||= Hash.new { |h, k| h[k] = {} }
    end

    # everything the parser remembers lives here. clear_caches! (runs on
    # reload_schema!) drops it all so DDL-heavy scripts don't leak prism
    # trees and dev-reload never serves stale ASTs. no whole-file tree
    # cache on purpose - candidate_blocks indexes once per file, buckets
    # blocks per line, then lets the tree die. per-Ractor: clears only
    # the current Ractor's caches (other Ractors retain theirs).
    def self.clear_caches!
      Ractor.current[CACHES_KEY] = Hash.new { |h, k| h[k] = {} }
    end

    # the per-Ractor cache hash for a given purpose.
    def self.cache_for(purpose)
      caches[purpose]
    end

    # the per-Ractor line cache (file+line -> Prism::BlockNode[]).
    def self.line_cache
      caches[:line]
    end

    # ====================================================================
    # where blocks: one expression in, one AST::Node out. `scope` maps
    # table names in play (base + joins) to their schemas; when present,
    # `tags.tag` in a block resolves to a qualified column.
    # ====================================================================
    def self.parse_block(block, schema, scope = nil)
      _parse_with_candidates(block, :where) { |node| translate_where(node, schema, scope) }
    end

    # ====================================================================
    # derive blocks: one AST node per statement out. bare columns,
    # function calls, window chains, all of it.
    # ====================================================================
    def self.parse_derive(block, schema)
      _parse_with_candidates(block, :derive) do |node|
        unwrap_statements(node).map { |stmt| translate_derive(stmt, schema) }
      end
    end

    # ====================================================================
    # define_relation blocks: ColumnDefinitions, ForeignKeys and Indexes out.
    # ====================================================================
    def self.parse_ddl(block)
      _parse_with_candidates(block, :ddl) do |node|
        unwrap_statements(node).map { |stmt| translate_ddl_stmt(stmt) }
      end
    end

    # ====================================================================
    # update blocks: { col => value } out. `age 17` and `age = 26; age`
    # both work.
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
            # trailing `age` in `age = 26; age` keeps ruby from whining
            # about unused variables. ignored.
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

    # wrong block, try the next candidate. different from UnknownColumnError
    # and friends, which mean right block, bad content.
    class BlockMismatch < StandardError; end

    # first lookup for a file parses once, walks once, buckets every block
    # by line. later lines are hash hits. tree dies after indexing - only
    # per-line block subtrees stick around.
    def self.candidate_blocks(file, line)
      lc = line_cache
      key = [file, line]
      return lc[key] if lc.key?(key)
      index_file_blocks(file)
      lc[key] ||= []
    end

    def self.index_file_blocks(file)
      lc = line_cache
      marker = [file, :__indexed__]
      return if lc.key?(marker)
      tree = Prism.parse_file(file).value
      bucket = Hash.new { |h, k| h[k] = [] }
      collect_blocks_into(tree, bucket)
      bucket.each { |ln, nodes| lc[[file, ln]] = nodes }
      lc[marker] = true
      # `tree` falls out of scope here by design (see clear_caches! note).
    end

    def self.collect_blocks_into(node, bucket)
      return unless node.respond_to?(:location)
      bucket[node.location.start_line] << node if node.is_a?(Prism::BlockNode)
      if node.compact_child_nodes
        node.compact_child_nodes.each { |c| collect_blocks_into(c, bucket) }
      end
    end

    # chained blocks on one line (`.where{}.or{}`) all live on the same
    # line, so consume candidates in call order: each call scans forward
    # from a per-key cursor (wrapping) and takes the first candidate that
    # parses. the wrap matters — a chained line inside a loop must resolve
    # 0,1,0,1... across iterations, not drift. single-block lines always
    # resolve index 0, so existing behavior is unchanged.
    # real errors (UnknownColumn etc.) still blow up - only shape
    # mismatches move on to the next candidate.
    def self._parse_with_candidates(block, purpose, &translator)
      file, line = block.source_location
      raise "Cannot parse block without a file source" unless file

      cache = cache_for(purpose)
      candidates = candidate_blocks(file, line)
      raise "No parseable #{purpose} block found at #{file}:#{line}" if candidates.empty?

      cursor_key = [file, line, purpose, :cursor]
      cursor = cache[cursor_key] || 0

      result = nil
      result_index = nil
      candidates.size.times do |step|
        idx = (cursor + step) % candidates.size
        cache_key = [file, line, purpose, idx]
        if cache.key?(cache_key)
          result = cache[cache_key]
          result_index = idx
          break
        end
        begin
          result = translator.call(candidates[idx])
          result_index = idx
          cache[cache_key] = result
          break
        rescue BlockMismatch
          next
        end
      end

      raise "No parseable #{purpose} block found at #{file}:#{line}" if result.nil?
      cache[cursor_key] = (result_index + 1) % candidates.size
      result
    end

    def self.unwrap_statements(block_node)
      body = block_node.body
      body = body.body if body.is_a?(Prism::ParenthesesNode)
      # body is now StatementsNode
      body.body.reject { |stmt| stmt.is_a?(Prism::ProgramNode) }
    end

    # ----- Where translation -----
    def self.translate_where(node, schema, scope = nil)
      hook = WhereOperators.call(node, schema)
      return hook if hook
      case node
      when Prism::BlockNode
        translate_where(node.body, schema, scope)
      when Prism::StatementsNode
        translate_where(node.body.first, schema, scope)
      when Prism::ParenthesesNode
        translate_where(node.body, schema, scope)
      when Prism::CallNode
          # `.in()` takes any number of args (including zero), so catch it
          # before the binary-op path that assumes exactly one.
          if node.name == :in && node.receiver
            lhs  = translate_where(node.receiver, schema, scope)
            vals = node.arguments ? node.arguments.arguments.map { |a| translate_where(a, schema, scope) } : []
            return AST::In.new(lhs, vals)
          end

          if node.name == :proc && node.block
            translate_where(node.block, schema, scope)
          elsif node.name == :between? && node.receiver
            # column.between?(low, high)
            col = translate_where(node.receiver, schema, scope)
            args = node.arguments.arguments
            raise BlockMismatch, "between? requires exactly 2 arguments" unless args.size == 2
            low = translate_where(args[0], schema, scope)
            high = translate_where(args[1], schema, scope)
            AST::Between.new(col, low, high)
          elsif node.receiver.nil? && node.arguments.nil?
            validate_column!(node.name, schema)
            AST::Column.new(node.name)
          elsif node.receiver.nil? && node.arguments
            # bare function call: `count(id)`, `sum(age)`, etc.
            # useful for HAVING clauses.
            args = node.arguments.arguments.map { |a| translate_where(a, schema, scope) }
            AST::Function.new(node.name, args)
          elsif node.receiver && node.arguments.nil?
            # standalone qualified ref: `tags.tag` (as a between?/in
            # receiver, say). anything else here is still a mismatch.
            qualified = try_qualified(node.receiver, node.name, schema, scope)
            return qualified if qualified
            join_first_hint(node.receiver, node.name, schema, scope)
            raise BlockMismatch, "Unsupported call: #{node.inspect}"
          elsif node.receiver && node.arguments

          left      = translate_receiver(node, schema, scope)
          right_arg = node.arguments.arguments.first

          if node.name == :== && right_arg.is_a?(Prism::ArrayNode)
            vals = right_arg.elements.map { |e| translate_where(e, schema, scope) }
            return AST::In.new(left, vals)
          end

          if node.name == :"!=" && right_arg.is_a?(Prism::ArrayNode)
            vals = right_arg.elements.map { |e| translate_where(e, schema, scope) }
            return AST::NotIn.new(left, vals)
          end

          right = translate_where(right_arg, schema, scope)

          # handle nil comparisons specially: == nil -> IS NULL, != nil -> IS NOT NULL
          if right.is_a?(AST::Literal) && right.value.nil?
            return case node.name
                   when :==   then AST::IsNull.new(left)
                   when :"!=" then AST::IsNotNull.new(left)
                   end
          end

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
        AST::And.new(translate_where(node.left, schema, scope), translate_where(node.right, schema, scope))
      when Prism::OrNode
        AST::Or.new(translate_where(node.left, schema, scope), translate_where(node.right, schema, scope))
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

    # left side of a binary op. usually a plain column; `tags.tag` (a
    # bareword call on a bareword table in scope) resolves qualified.
    def self.translate_receiver(node, schema, scope)
      recv = node.receiver
      qualified = try_qualified(recv, node.name, schema, scope)
      return qualified if qualified
      join_first_hint(recv, node.name, schema, scope)
      translate_where(recv, schema, scope)
    end

    # `recv` must be a bareword (`tags`), `col` the method on it (`tag`).
    # plain base columns win ties so old queries keep working. returns nil
    # when this isn't a qualified ref at all (caller falls through).
    def self.try_qualified(recv, col, schema, scope)
      return nil unless recv.is_a?(Prism::CallNode) && recv.receiver.nil? && recv.arguments.nil?
      return nil if schema[:columns].include?(recv.name)
      return nil unless scope && scope.key?(recv.name)

      validate_column!(col, scope[recv.name])
      AST::Column.new(col, table: recv.name)
    end

    # same shape, but the table isn't joined (yet). happens when the where
    # runs before the join in the chain — tell them the order matters
    # instead of a confusing column error. nil when not applicable.
    def self.join_first_hint(recv, col, schema, scope)
      return nil unless recv.is_a?(Prism::CallNode) && recv.receiver.nil? && recv.arguments.nil?
      return nil if schema[:columns].include?(recv.name)
      return nil if scope && scope.key?(recv.name)
      return nil unless Diamond.engine.schema_cache.key?(recv.name)

      raise ArgumentError,
            "filtering on '#{recv.name}.#{col}' needs `.join(:#{recv.name})` first " \
            "(joins must come before the where that filters on them)"
    end

    # ----- Derive translation -----
    def self.translate_derive(node, schema)
      hook = DeriveOperators.call(node, schema)
      return hook if hook
      case node
      when Prism::CallNode
        positional, kwargs = split_args(node)

        if node.receiver.nil? && positional.empty? && kwargs.empty?
          validate_column!(node.name, schema)
          return AST::Column.new(node.name)
        end

        if node.receiver.nil? && !positional.empty? && kwargs.empty?
          args = positional.map { |a| translate_derive(a, schema) }
          return AST::Function.new(node.name, args)
        end

        if node.name == :over && node.receiver
          inner = node.receiver
          unless inner.is_a?(Prism::CallNode) && inner.receiver.nil? && inner.arguments.nil?
            raise BlockMismatch, "Window function receiver must be a bareword call: #{inner.inspect}"
          end
          unless WINDOW_FUNCS.include?(inner.name)
            raise BlockMismatch, "Not a window function: #{inner.name}"
          end
          # kwargs already parsed above - don't walk the args twice.
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

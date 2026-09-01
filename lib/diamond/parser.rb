require 'prism'

module Diamond
  module Parser
    @file_cache = {}
    @ast_cache = {} 

    def self.parse_block(block, schema)
      file, line = block.source_location
      raise "Cannot parse block without a file source" unless file

      cache_key = [file, line]
      
      return @ast_cache[cache_key] if @ast_cache.key?(cache_key)

      @file_cache[file] ||= Prism.parse_file(file).value
      block_node = find_block_node(@file_cache[file], line)
      raise "Could not locate block in AST at #{file}:#{line}" unless block_node

      @ast_cache[cache_key] = translate(block_node, schema)
    end

    def self.find_block_node(node, line)
      return nil unless node.respond_to?(:location)

      if node.is_a?(Prism::BlockNode) && node.location.start_line == line
        return node
      end

      node.compact_child_nodes.each do |child|
        found = find_block_node(child, line)
        return found if found
      end
      nil
    end

    def self.translate(node, schema)
      case node
      when Prism::BlockNode
        # Dive into the block's body (StatementsNode)
        translate(node.body, schema)
      when Prism::StatementsNode
        # Execute the first (and usually only) statement in the block
        translate(node.body.first, schema)
      when Prism::ParenthesesNode
        # Unwrap parentheses like (age > 15)
        translate(node.body, schema)
      when Prism::CallNode
        if node.name == :proc && node.block
          translate(node.block, schema)
        elsif node.receiver.nil? && node.arguments.nil?
          validate_column!(node.name, schema)
          AST::Column.new(node.name)
        elsif node.receiver && node.arguments
          left = translate(node.receiver, schema)
          right = translate(node.arguments.arguments.first, schema)
          
          case node.name
          when :> then AST::GreaterThan.new(left, right)
          when :< then AST::LessThan.new(left, right)
          when :== then AST::Equality.new(left, right)
          when :"!=" then AST::NotEqual.new(left, right)
          when :&, :"&&" then AST::And.new(left, right) # Added bitwise & alias
          when :|, :"||" then AST::Or.new(left, right)  # Added bitwise | alias
          else
            raise "Unsupported operator: #{node.name}"
          end
        else
          raise "Unsupported call: #{node.inspect}"
        end
      when Prism::AndNode
        AST::And.new(translate(node.left, schema), translate(node.right, schema))
      when Prism::OrNode
        AST::Or.new(translate(node.left, schema), translate(node.right, schema))
      when Prism::IntegerNode
        AST::Literal.new(Integer(node.slice))
      when Prism::StringNode
        AST::Literal.new(node.unescaped)
      when Prism::NilNode
        AST::Literal.new(nil)
      when Prism::TrueNode
        AST::Literal.new(true)
      when Prism::FalseNode
        AST::Literal.new(false)
      else
        raise "Unsupported Prism AST Node: #{node.class}"
      end
    end

    def self.validate_column!(name, schema)
      # CTE Bypass: If the schema is empty (e.g., querying a CTE), 
      # we don't know the columns, so allow anything.
      return if schema[:columns].empty?
      return if schema[:columns].include?(name)

      closest = schema[:columns].map(&:to_s)
      suggestions = DidYouMean::SpellChecker.new(dictionary: closest).correct(name.to_s)
      
      msg = "Table has no column '#{name}'."
      msg += " Did you mean '#{suggestions.first}'?" unless suggestions.empty?
      
      raise Diamond::UnknownColumnError, msg
    end
  end
end
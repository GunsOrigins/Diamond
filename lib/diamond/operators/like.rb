module Diamond
  module Operators
    # LIKE operator — `where { name =~ pattern }` where pattern is a String
    # or a Regexp.
    #
    # String RHS is passed through as the LIKE pattern verbatim. `%` matches
    # any sequence, `_` matches any single char. Backslash escapes literal
    # `%`, `_`, and `\` themselves.
    #
    # Regexp RHS is translated to a LIKE pattern with documented rules:
    #
    #   literal chars   -> literal (% and _ get backslash-escaped)
    #   \X              -> X (with %, _, \ escaped for LIKE)
    #   .  (unescaped)  -> _    any single char
    #   .*              -> %    any sequence
    #   ^   at start    -> dropped (LIKE doesn't anchor)
    #   $   at end      -> dropped (LIKE doesn't anchor)
    #
    # Anything else (character classes [], alternation |, groups (), quantifiers
    # + ? {n,m}, lookahead/lookbehind) raises ArgumentError. Honest, not magical.
    module Like
      PRIORITY = 60

      def self.priority
        PRIORITY
      end

      def self.parse_where(node, schema)
        return nil unless node.is_a?(Prism::CallNode)
        return nil unless node.name == :=~
        return nil unless node.receiver
        return nil unless node.arguments
        return nil unless node.arguments.arguments.size == 1

        rhs_node = node.arguments.arguments.first
        pattern =
          case rhs_node
          when Prism::StringNode
            rhs_node.unescaped
          when Prism::RegularExpressionNode
            regexp_to_like(rhs_node)
          else
            return nil
          end

        lhs = Parser.translate_where(node.receiver, schema)
        AST::Like.new(lhs, AST::Literal.new(pattern))
      end

      def self.handles?(node)
        node.is_a?(AST::Like)
      end

      def self.render(node, params)
        params << node.right.value
        "#{node.left.name} LIKE ?"
      end

      # ----- Regexp -> LIKE translation -----

      UNSUPPORTED = {
        '(' => 'groups'.freeze,
        ')' => 'groups'.freeze,
        '|' => 'alternation'.freeze,
        '+' => '+ quantifier'.freeze,
        '?' => '? quantifier'.freeze,
        '{' => '{n,m} quantifier'.freeze,
        '[' => 'character class'.freeze
      }.freeze

      def self.regexp_to_like(regexp_node)
        # `.content` is the raw source between the slashes; `.unescaped`
        # would already process regex-level escapes (\n -> newline), which
        # we don't want — we're translating the source, not matching it.
        source = regexp_node.content
        out = String.new
        i = 0
        len = source.length

        leading_anchor = false
        trailing_anchor = false

        if len > 0 && source[0] == '^'
          leading_anchor = true
          i += 1
        end
        if len - i > 0 && source[len - 1] == '$'
          trailing_anchor = true
          len -= 1
        end

        while i < len
          c = source[i]
          if c == '\\' && i + 1 < len
            nxt = source[i + 1]
            out << escape_like(nxt)
            i += 2
          elsif c == '.'
            # peek for .*
            if i + 1 < len && source[i + 1] == '*'
              out << '%'
              i += 2
            else
              out << '_'
              i += 1
            end
          elsif UNSUPPORTED.key?(c)
            raise ArgumentError,
                  "Regexp feature #{UNSUPPORTED[c].inspect} (#{c.inspect}) " \
                  "is not supported by LIKE; rewrite without it"
          else
            out << escape_like(c)
            i += 1
          end
        end

        # ^X -> LIKE 'X%'   (starts with)
        # X$ -> LIKE '%X'   (ends with)
        # ^X$ -> LIKE 'X'   (exact)
        # X -> LIKE '%X%'   (anywhere)
        if leading_anchor && trailing_anchor
          out
        elsif leading_anchor
          "#{out}%"
        elsif trailing_anchor
          "%#{out}"
        else
          "%#{out}%"
        end
      end

      LIKE_WILDCARDS = { '%' => '\%'.freeze, '_' => '\_'.freeze, '\\' => '\\\\'.freeze }.freeze

      def self.escape_like(ch)
        LIKE_WILDCARDS.fetch(ch, ch)
      end
    end
  end
end

Diamond::Parser::WhereOperators.register(Diamond::Operators::Like)
Diamond::Compiler::Operators.register(Diamond::Operators::Like)

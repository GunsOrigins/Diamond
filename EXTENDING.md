# Extending Diamond

Diamond is built around a Prism-driven pipeline: a Ruby DSL block becomes an AST node, then an AST node becomes SQL. The contract for plugging into that pipeline is the **operator**.

## The operator contract

An operator is a module under `lib/diamond/operators/` (or anywhere — registration is by side effect). It exposes four class methods:

```ruby
module Diamond
  module Operators
    module MyOp
      PRIORITY = 60

      def self.priority;           PRIORITY; end
      def self.parse_where(node, schema);  end   # Prism node -> AST::Node | nil
      def self.parse_derive(node, schema); end   # optional, same shape
      def self.handles?(node);               end   # AST::Node -> Bool
      def self.render(node, params);         end   # AST::Node -> SQL fragment
    end
  end
end
```

Register with both halves of the pipeline:

```ruby
Diamond::Parser::WhereOperators.register(Diamond::Operators::MyOp)
Diamond::Compiler::Operators.register(Diamond::Operators::MyOp)
```

## Priority

Higher `PRIORITY` runs first. Built-in operators are implicit priority 0 — they are the fallthrough. External operators sit above the built-ins and intercept nodes before the built-in case statements see them.

If two external operators match the same node, the higher-priority one wins. The first one to return a non-nil `AST::Node` (parser) or claim `handles? == true` (compiler) is the one that runs.

`AST::Column` and `AST::Literal` are primitives. The foundation stays stable across extensions.

## Reference: the LIKE operator

`lib/diamond/operators/like.rb` is the canonical example. It adds `where { name =~ pattern }` where `pattern` is a String (LIKE pattern) or a Regexp (translated to LIKE honestly — `^`, `$`, `.`, `.*`, `\X` supported; character classes, alternation, groups, quantifiers raise with a clear message).

The file is structured as:

1. `parse_where` — recognise the Prism `CallNode` for `=~`, translate String/Regexp RHS into an `AST::Like` node containing a plain LIKE pattern.
2. `handles?` — claim `AST::Like` nodes.
3. `render` — emit `lhs LIKE ?` with the pattern bound as a parameter.
4. `regexp_to_like` — best-effort Regexp-to-LIKE translation. Unsupported features raise `ArgumentError` with a clear message.
5. Two `register` calls at the bottom of the file.

Read it once. Writing the next operator is a matter of substituting the shapes.

## Writing a new operator

Suppose you want `where { name !=~ pattern }` (NOT LIKE). The skeleton:

```ruby
# lib/diamond/operators/not_like.rb
require_relative '../ast'
require_relative '../../parser/registry'
require_relative '../../compiler/registry'

module Diamond
  module Operators
    module NotLike
      PRIORITY = 60

      def self.priority; PRIORITY; end

      def self.parse_where(node, schema)
        return nil unless node.is_a?(Prism::CallNode)
        return nil unless node.name == :"!=~"
        return nil unless node.receiver && node.arguments&.arguments&.size == 1
        # ... translate RHS, build AST::NotLike ...
      end

      def self.handles?(node)
        node.is_a?(AST::NotLike)
      end

      def self.render(node, params)
        params << node.right.value
        "#{node.left.name} NOT LIKE ?"
      end
    end
  end
end

Diamond::Parser::WhereOperators.register(Diamond::Operators::NotLike)
Diamond::Compiler::Operators.register(Diamond::Operators::NotLike)
```

You'd add `AST::NotLike < AST::BinaryOp` to `lib/diamond/ast.rb`, then `require_relative 'diamond/operators/not_like'` from `lib/diamond.rb`. Done.

## Testing an operator

A pattern that has worked well in the spec suite:

```ruby
describe "MyOp operator" do
  it "parses and renders" do
    q = Users.where { name my_op "x%" }
    sql, params = Diamond::Compiler::Base.compile(q.table, q.ast)
    _(sql).must_match(/name MY_OP \?/)
    _(params).must_equal ["x%"]
  end

  it "raises for unsupported shapes" do
    _(proc { Users.where { name my_op 42 } }).must_raise ArgumentError
  end
end
```

The `Operator registry` describe block in `spec/diamond_spec.rb` shows how to register an anonymous operator mid-test and verify the dispatch path works for arbitrary shapes — useful when building a new operator that does not match any built-in Prism node shape.

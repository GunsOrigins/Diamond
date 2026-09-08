module Diamond
  # Operator contract — modules under lib/diamond/operators/ implement this.
  #
  # Three registries consult operators at dispatch time:
  #
  #   Parser::WhereOperators  — Prism node -> AST::Node (where blocks)
  #   Parser::DeriveOperators — Prism node -> AST::Node (derive blocks)
  #   Compiler::Operators     — AST::Node  -> SQL fragment (SQL rendering)
  #
  # Built-in operators are the fallthrough (implicit priority 0). External
  # operators run first, sorted by descending priority; first non-nil result
  # wins. AST::Column and AST::Literal are primitives, not operators — the
  # foundation stays stable across extensions.
  #
  # Canonical implementation: lib/diamond/operators/like.rb.
  module Operator
    # An operator module exposes:
    #
    #   PRIORITY            - Integer. Higher runs first. Built-ins are 0.
    #   priority            - class method returning PRIORITY
    #   parse_where(node, schema)  -> AST::Node | nil
    #   parse_derive(node, schema) -> AST::Node | nil
    #   handles?(node) -> Bool
    #   render(node, params) -> String  (mutates params)
    #
    # Register by calling:
    #   Parser::WhereOperators.register(MyOp)
    #   Parser::DeriveOperators.register(MyOp)  # optional
    #   Compiler::Operators.register(MyOp)
  end
end

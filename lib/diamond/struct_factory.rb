require_relative 'compiler/dql'

module Diamond
  module StructFactory
    @struct_cache = {}

    # struct classes pile up per projection shape. drop them here.
    def self.clear_caches!
      @struct_cache = {}
    end

    def self.create(table, row_hash, projection_nodes = nil)
      members = resolve_members(projection_nodes, table)

      member_names = members.map(&:first)
      klass = struct_class_for(table, member_names, projection_nodes)

      values = members.map { |member, sql_name| row_hash[sql_name] }
      klass.new(*values).freeze
    end

    # array rows land positionally, no hash lookups. select order ==
    # member order, `*` included.
    def self.create_from_array(table, row_array, projection_nodes = nil)
      members = resolve_members(projection_nodes, table)

      member_names = members.map(&:first)
      klass = struct_class_for(table, member_names, projection_nodes)

      klass.new(*row_array).freeze
    end

    def self.struct_class_for(table, member_names, projection_nodes)
      # NUL can't appear in identifiers, so [a_b, c] and [a, b_c] stop colliding.
      cache_key = projection_nodes ? "#{table.name}\0#{member_names.join("\0")}" : table.name.to_s

      unless @struct_cache[cache_key]
        @struct_cache[cache_key] = Struct.new(*member_names) do
          def save; raise Diamond::InertObjectError, "Data is inert! Use the Table proxy to update."; end
        end
      end

      @struct_cache[cache_key]
    end

    def self.resolve_members(projection_nodes, table)
      if projection_nodes.nil? || projection_nodes.empty?
        return table.schema[:columns].map { |c| [c, c.to_s] }
      end

      projection_nodes.map do |node|
        sql_name    = compile_node(node)
        member_name = member_name_for(node)
        [member_name, sql_name]
      end
    end

    def self.compile_node(node)
      Diamond::Compiler::DQL.translate_node(node, [])
    end

    def self.member_name_for(node)
      case node
      when Diamond::AST::Column
        node.name
      when Diamond::AST::Function
        first_arg = node.args.first
        suffix = case first_arg
                 when Diamond::AST::Column then first_arg.name
                 when Diamond::AST::Literal
                   val = first_arg.value
                   val.is_a?(String) ? val : (val.nil? ? 'nil' : val.to_s)
                 else
                   'all'
                 end
        :"#{node.name.downcase}_#{suffix}"
      when Diamond::AST::WindowFunction
        parts = []
        parts.concat(node.partition_by) unless node.partition_by.empty?
        parts.concat(node.order_by) unless node.order_by.empty?
        suffix = parts.empty? ? 'all' : parts.join('_')
        :"#{node.func_name.downcase}_#{suffix}"
      else
        raise "Unknown projection node: #{node.class}"
      end
    end
  end
end

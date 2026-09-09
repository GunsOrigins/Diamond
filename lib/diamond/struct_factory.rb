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

    # Build a frozen struct from an Extralite::Transform result row. The
    # row shape is a Hash keyed by the transform spec's keys; for parent
    # columns the key is the bare column name (e.g. "id"), for eagerly-
    # loaded children the key is the table name and the value is an Array
    # of nested Hashes (each becoming a child struct).
    #
    # Post-processes the Extralite output:
    #   - strips the "table." prefix from nested column names
    #   - drops null sentinel rows LEFT JOIN leaves for parents without kids
    #   - deduplicates children by primary key (Extralite only dedupes
    #     within a single parent row's join group, not across the join)
    def self.create_eager(parent_table, row)
      members = []
      table_sym = parent_table.is_a?(Symbol) ? parent_table : parent_table.name

      row.each do |key, value|
        if value.is_a?(Array)
          child_table_sym = key.to_sym
          child_schema = Diamond.engine.schema_cache[child_table_sym]
          child_pk = child_schema[:primary_key]

          # strip table. prefix from each child row's keys
          stripped = value.map do |child_row|
            child_row.each_with_object({}) do |(k, v), h|
              short = k.to_s.sub(/^#{Regexp.escape(child_table_sym.to_s)}\./, '').to_sym
              h[short] = v
            end
          end

          # drop null sentinels (Extralite leaves these for parents without
          # children after a LEFT JOIN)
          stripped.reject! { |child_row| child_row.values.all?(&:nil?) }

          # dedupe by primary key
          if child_pk
            seen = {}
            stripped = stripped.reject do |r|
              pk_val = r[child_pk]
              if seen[pk_val]
                true
              else
                seen[pk_val] = true
                false
              end
            end
          end

          child_structs = stripped.map { |child_row| create_eager(child_table_sym, child_row) }
          members << [child_table_sym, child_structs]
        else
          members << [key.to_sym, value]
        end
      end

      member_names = members.map(&:first)
      cache_key = "#{table_sym}\0#{member_names.join("\0")}"
      klass = @struct_cache[cache_key] ||= Struct.new(*member_names) do
        def save; raise Diamond::InertObjectError, "Data is inert! Use the Table proxy to update."; end
      end
      klass.new(*members.map(&:last)).freeze
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
        return table.schema[:columns].map { |c| [c, c] }
      end

      projection_nodes.map do |node|
        sql_name    = compile_node(node)
        member_name = member_name_for(node)
        [member_name, sql_name]
      end
    end

    def self.compile_node(node)
      # Extralite returns symbol keys for both columns and function results
      # (e.g. { :id => 1, :"COUNT(id)" => 4 }). We mirror that here so
      # `row_hash[sql_name]` hits the right key.
      case node
      when Diamond::AST::Column
        node.name.to_sym
      when Diamond::AST::Function
        Diamond::Compiler::DQL.translate_node(node, []).to_sym
      when Diamond::AST::WindowFunction
        Diamond::Compiler::DQL.translate_node(node, []).to_sym
      else
        Diamond::Compiler::DQL.translate_node(node, []).to_sym
      end
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

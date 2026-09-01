module Diamond
  module StructFactory
    @struct_cache = {}

    def self.create(table, row_hash, projected_columns = nil)
      # If projected_columns are specified, use them. Otherwise use table schema.
      columns_to_map = projected_columns || table.schema[:columns]
      
      # Cache key needs to account for projections so we don't conflict with full structs
      cache_key = projected_columns ? "#{table.name}_#{projected_columns.join('_')}" : table.name.to_s
      
      unless @struct_cache[cache_key]
        @struct_cache[cache_key] = Struct.new(*columns_to_map) do
          def save; raise Diamond::InertObjectError, "Data is inert! Use the Table proxy to update."; end
        end
      end

      struct_class = @struct_cache[cache_key]
      values = columns_to_map.map { |c| row_hash[c.to_s] }
      struct = struct_class.new(*values)
      struct.freeze
      struct
    end
  end
end
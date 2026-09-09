module Diamond
  # streams rows out of a prepared Extralite statement, one frozen struct at a time.
  #
  # statement gets closed by `ensure` when iteration completes (or breaks, or
  # raises), plus a GC finalizer for cursors dropped on the floor. the
  # finalizer is built by ::make_finalizer so it never closes over the cursor
  # itself. rows arrive as arrays (positions match the SELECT order), avoiding
  # hash allocation per row.
  class Cursor
    include Enumerable

    def self.make_finalizer(stmt)
      ->(_id) {
        begin
          stmt.close unless stmt.closed?
        rescue StandardError
          # best effort - finalizers must not raise
        end
      }
    end

    def initialize(table, stmt, projected_columns)
      @table = table
      @stmt = stmt
      @projected_columns = projected_columns

      ObjectSpace.define_finalizer(self, self.class.make_finalizer(@stmt))
    end

    def each
      return self unless block_given?
      begin
        @stmt.each do |row|
          if row.is_a?(Hash)
            yield Diamond::StructFactory.create(@table, row, @projected_columns)
          else
            yield Diamond::StructFactory.create_from_array(@table, row, @projected_columns)
          end
        end
      ensure
        begin
          @stmt.close unless @stmt.closed?
        rescue StandardError
          # ensure must not raise
        end
      end
    end
  end
end

module Diamond
  # streams rows out of a prepared statement, one frozen struct at a time.
  #
  # statement gets closed by `ensure` when you're done (or break, or blow
  # up), plus a GC finalizer for cursors you just drop on the floor. the
  # finalizer is built by ::make_finalizer so it never closes over the
  # cursor itself.
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
      db = Diamond.engine.db
      prev_hash_mode = db.results_as_hash
      # array rows, not hashes - half the garbage per row. values land
      # positionally (select order == member order, `*` included).
      # flips a process-global flag for the loop; single connection so
      # nobody else can interleave here. ensure flips it back.
      db.results_as_hash = false
      begin
        @stmt.execute.each do |row_array|
          yield Diamond::StructFactory.create_from_array(@table, row_array, @projected_columns)
        end
      ensure
        begin
          db.results_as_hash = prev_hash_mode
        rescue StandardError
          # restore must not raise
        end
        begin
          @stmt.close unless @stmt.closed?
        rescue StandardError
          # ensure must not raise
        end
      end
    end
  end
end

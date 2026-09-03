module Diamond
  # Streaming wrapper around a prepared SQLite statement. The cursor is
  # iterated lazily — the SQLite statement stays open until iteration
  # completes (or the Cursor is garbage-collected).
  #
  # Two safety nets close the underlying statement:
  #   1. ensure after iteration completes (normal path)
  #   2. ensure after iteration breaks via `break` or propagates an exception
  #   3. ObjectSpace.define_finalizer — if the Cursor is GC'd without
  #      being iterated to completion, the SQLite statement is closed too.
  #      The finalizer proc is built by a class method so it closes over
  #      only the stmt, never the Cursor instance itself (avoids the
  #      "finalizer references object to be finalized" warning).
  class Cursor
    include Enumerable

    def self.make_finalizer(stmt)
      ->(_id) {
        begin
          stmt.close unless stmt.closed?
        rescue StandardError
          # best effort — finalizers must not raise
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
      @stmt.execute.each do |row_hash|
        yield Diamond::StructFactory.create(@table, row_hash, @projected_columns)
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

require_relative 'dql'

module Diamond
  module Compiler
    module DML
      def self.compile_insert(table, insert_node)
        cols = insert_node.data.keys
        placeholders = (['?'] * cols.size).join(', ')
        sql = "INSERT INTO #{table.name} (#{cols.join(', ')}) VALUES (#{placeholders})"
        params = insert_node.data.values

        stmt = Diamond.engine.db.prepare(sql)
        begin
          stmt.bind_params(params)
          stmt.execute
        ensure
          begin
            stmt.close unless stmt.closed?
          rescue StandardError
            # ensure must not raise
          end
        end
        Diamond.engine.db.last_insert_row_id
      end

      def self.compile_update(table, hash, where_nodes)
        params = []
        set_clause = hash.keys.map { |k| "#{k} = ?" }.join(', ')
        params.concat(hash.values)

        sql = "UPDATE #{table.name} SET #{set_clause}"
        unless where_nodes.empty?
          conditions = where_nodes.map { |w| DQL.translate_node(w.condition, params) }
          sql += " WHERE " + conditions.join(' AND ')
        end

        stmt = Diamond.engine.db.prepare(sql)
        begin
          stmt.bind_params(params)
          stmt.execute
        ensure
          begin
            stmt.close unless stmt.closed?
          rescue StandardError
            # ensure must not raise
          end
        end
        Diamond.engine.db.changes
      end

      def self.compile_delete(table, where_nodes)
        params = []
        sql = "DELETE FROM #{table.name}"
        unless where_nodes.empty?
          conditions = where_nodes.map { |w| DQL.translate_node(w.condition, params) }
          sql += " WHERE " + conditions.join(' AND ')
        end

        stmt = Diamond.engine.db.prepare(sql)
        begin
          stmt.bind_params(params)
          stmt.execute
        ensure
          begin
            stmt.close unless stmt.closed?
          rescue StandardError
            # ensure must not raise
          end
        end
        Diamond.engine.db.changes
      end
    end
  end
end

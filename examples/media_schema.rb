#!/usr/bin/env ruby
# examples/media_schema.rb
# Proof-of-concept: convert the raw SQL schema (PRAGMA + 2 tables + 1 index)
# into the Diamond DSL. Then exercise it to verify FK CASCADE and the
# UNIQUE INDEX actually fire at the SQLite layer.
#
# Run:   ruby examples/media_schema.rb
#
# This script is intentionally NOT committed — it's a smoke test for the
# directive conversion, not a permanent fixture. Living under examples/
# so it can be re-run any time the schema evolves.

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'diamond'

Diamond.wake_up(':memory:')

# ----------------------------------------------------------------------
# Schema definition
# ----------------------------------------------------------------------

Diamond.define_relation(:media_nodes) do |t|
  t.attribute :id, Integer, primary_key: true, nullable: false
  t.attribute :parent_id, Integer
  t.foreign_key :parent_id, :media_nodes, on_delete: :cascade   # self-reference

  t.attribute :title, String, nullable: false
  t.attribute :kind, String, nullable: false
  t.attribute :position, Integer                               # nullable
  t.attribute :status, String, nullable: false

  t.attribute :created_at, String, nullable: false
  t.attribute :updated_at, String, nullable: false

  t.index :parent_id, :position, unique: true, name: :idx_media_nodes_parent_position
end

Diamond.define_relation(:journal_entries) do |t|
  t.attribute :id, Integer, primary_key: true, nullable: false

  t.attribute :media_node_id, Integer, nullable: false
  t.foreign_key :media_node_id, :media_nodes, on_delete: :cascade

  t.attribute :content, String, nullable: false

  t.attribute :created_at, String, nullable: false
  t.attribute :updated_at, String, nullable: false
end

# ----------------------------------------------------------------------
# Sanity-check the rendered DDL
# ----------------------------------------------------------------------

puts '== Schema SQL =='
puts Diamond::Compiler::DDL.compile(Diamond._build_relation(:media_nodes) do |t|
  t.attribute :id, Integer, primary_key: true, nullable: false
  t.attribute :parent_id, Integer
  t.foreign_key :parent_id, :media_nodes, on_delete: :cascade
  t.attribute :title, String, nullable: false
  t.attribute :kind, String, nullable: false
  t.attribute :position, Integer
  t.attribute :status, String, nullable: false
  t.attribute :created_at, String, nullable: false
  t.attribute :updated_at, String, nullable: false
end).first
puts ''

# ----------------------------------------------------------------------
# PRAGMA check
# ----------------------------------------------------------------------

pragma_value = Diamond.engine.db.execute('PRAGMA foreign_keys').first.values.first
puts "PRAGMA foreign_keys = #{pragma_value} (expected 1)"

# ----------------------------------------------------------------------
# CASCADE: parent + child + journal. Delete parent -> all gone.
# ----------------------------------------------------------------------

parent_id = Diamond.engine.db.get_first_row(<<~SQL, [])
  INSERT INTO media_nodes (title, kind, position, status, created_at, updated_at)
  VALUES ('Root', 'folder', NULL, 'active', '2024-01-01', '2024-01-01');
SQL
last_id = Diamond.engine.db.last_insert_row_id

child_id = Diamond.engine.db.get_first_row(<<~SQL, [last_id])
  INSERT INTO media_nodes (parent_id, title, kind, position, status, created_at, updated_at)
  VALUES (?, 'Sub', 'folder', 1, 'active', '2024-01-01', '2024-01-01');
SQL
last_child_id = Diamond.engine.db.last_insert_row_id

journal_id = Diamond.engine.db.get_first_row(<<~SQL, [last_child_id])
  INSERT INTO journal_entries (media_node_id, content, created_at, updated_at)
  VALUES (?, 'Hello world', '2024-01-01', '2024-01-01');
SQL
last_journal_id = Diamond.engine.db.last_insert_row_id

puts ''
puts "Created: parent=#{last_id}, child=#{last_child_id}, journal=#{last_journal_id}"

Diamond.engine.db.execute('DELETE FROM media_nodes WHERE id = ?', last_id)
puts "After deleting parent #{last_id}:"

media_remaining = Diamond.engine.db.execute('SELECT id FROM media_nodes ORDER BY id').map { |r| r['id'] }
journal_remaining = Diamond.engine.db.execute('SELECT id FROM journal_entries ORDER BY id').map { |r| r['id'] }
puts "  media_nodes:  #{media_remaining}"
puts "  journal_entries: #{journal_remaining}"

unless media_remaining.empty? && journal_remaining.empty?
  warn 'CASCADE FAILED: child or journal survived parent deletion'
  exit 1
end

puts '  CASCADE works.'

# ----------------------------------------------------------------------
# UNIQUE INDEX: (parent_id, position). Same parent + same position -> fail.
# Note: SQLite UNIQUE INDEX allows multiple NULLs (NULL != NULL), so the
# tested rows must have a non-NULL parent_id for the constraint to fire.
# ----------------------------------------------------------------------

puts ''
puts '== UNIQUE INDEX =='

# Fresh parent to attach rows to (the previous root got cascade-deleted).
Diamond.engine.db.execute(<<~SQL, [])
  INSERT INTO media_nodes (title, kind, position, status, created_at, updated_at)
  VALUES ('FreshParent', 'folder', NULL, 'active', '2024-01-01', '2024-01-01');
SQL
fresh_parent_id = Diamond.engine.db.last_insert_row_id
puts "Fresh parent id=#{fresh_parent_id}"

Diamond.engine.db.execute(<<~SQL, [fresh_parent_id])
  INSERT INTO media_nodes (parent_id, title, kind, position, status, created_at, updated_at)
  VALUES (?, 'Sibling-1', 'folder', 1, 'active', '2024-01-01', '2024-01-01');
SQL
puts "Inserted sibling at (parent_id=#{fresh_parent_id}, position=1)."

begin
  Diamond.engine.db.execute(<<~SQL, [fresh_parent_id])
    INSERT INTO media_nodes (parent_id, title, kind, position, status, created_at, updated_at)
    VALUES (?, 'Sibling-2', 'folder', 1, 'active', '2024-01-01', '2024-01-01');
  SQL
  warn 'UNIQUE INDEX FAILED: duplicate (parent_id, position=1) insert succeeded'
  exit 1
rescue SQLite3::ConstraintException => e
  puts "Duplicate (#{fresh_parent_id}, 1) rejected: #{e.message.lines.first&.strip}"
  puts '  UNIQUE INDEX works.'
end

puts ''
puts '=== ALL DEMOS PASSED ==='

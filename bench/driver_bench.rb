# Benchmark extralite vs sqlite3 on a representative workload.
# Measures: memory footprint after materializing N rows, and throughput for
# the same query.

require 'extralite'
require 'sqlite3'

ROW_COUNTS = [1_000, 10_000, 100_000].freeze

def setup_extralite(rows)
  db = Extralite::Database.new(':memory:')
  db.execute('CREATE TABLE foo (id INTEGER PRIMARY KEY, name TEXT, age INTEGER, score REAL)')
  rows.times { |i| db.execute('INSERT INTO foo VALUES (?, ?, ?, ?)', i + 1, "name#{i}", 20 + (i % 50), (i % 100) / 7.0) }
  db
end

def setup_sqlite3(rows)
  db = SQLite3::Database.new(':memory:', results_as_hash: true)
  db.execute('CREATE TABLE foo (id INTEGER PRIMARY KEY, name TEXT, age INTEGER, score REAL)')
  rows.times { |i| db.execute('INSERT INTO foo VALUES (?, ?, ?, ?)', [i + 1, "name#{i}", 20 + (i % 50), (i % 100) / 7.0]) }
  db
end

def memory_after_materialize
  GC.start
  before = `ps -o rss= -p #{Process.pid}`.to_i
  yield
  GC.start
  after = `ps -o rss= -p #{Process.pid}`.to_i
  after - before
end

def time_extralite_materialize(rows)
  db = setup_extralite(rows)
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  results = db.query('SELECT * FROM foo')
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  results
  [elapsed, results.size]
end

def time_extralite_stream(rows)
  db = setup_extralite(rows)
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  count = 0
  stmt = db.prepare('SELECT * FROM foo')
  stmt.bind
  stmt.each { |_r| count += 1 }
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  stmt.close
  [elapsed, count]
end

def time_sqlite3_materialize(rows)
  db = setup_sqlite3(rows)
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  results = db.execute('SELECT * FROM foo')
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  results
  [elapsed, results.size]
end

puts "rows\t| extralite materialize (s)\t| extralite stream (s)\t| sqlite3 materialize (s)"
puts "-" * 100
ROW_COUNTS.each do |n|
  e_mat, _ = time_extralite_materialize(n)
  e_str, _ = time_extralite_stream(n)
  s_mat, _ = time_sqlite3_materialize(n)
  printf "%d\t| %.4f\t\t\t| %.4f\t\t| %.4f\n", n, e_mat, e_str, s_mat
end

puts
puts "Memory footprint (RSS delta in KB) after materializing rows"
puts "rows\t| extralite\t| sqlite3"
puts "-" * 50
ROW_COUNTS.each do |n|
  e_mem = memory_after_materialize { time_extralite_materialize(n) }
  s_mem = memory_after_materialize { time_sqlite3_materialize(n) }
  printf "%d\t| %d KB\t\t| %d KB\n", n, e_mem, s_mem
end

puts
puts "Memory footprint for STREAMING (each without keeping results)"
puts "rows\t| extralite stream\t| sqlite3 stream"
puts "-" * 50
ROW_COUNTS.each do |n|
  e_mem = memory_after_materialize { time_extralite_stream(n) }
  s_mem = memory_after_materialize do
    db = setup_sqlite3(n)
    db.execute('SELECT * FROM foo').each { |_r| }
  end
  printf "%d\t| %d KB\t\t| %d KB\n", n, e_mem, s_mem
end

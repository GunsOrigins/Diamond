require 'sqlite3'

# 1. Nuke the old DB if it exists so we start clean
File.delete("test.db") if File.exist?("test.db")

# 2. Create a fresh DB and inject the schema
db = SQLite3::Database.new("test.db")

db.execute(<<-SQL)
  CREATE TABLE users (
    id INTEGER PRIMARY KEY,
    name TEXT,
    age INTEGER
  );
SQL

db.execute("INSERT INTO users (name, age) VALUES ('Arle', 16)")
db.execute("INSERT INTO users (name, age) VALUES ('Carbuncle', 100)")

db.close

puts "test.db created and seeded!"
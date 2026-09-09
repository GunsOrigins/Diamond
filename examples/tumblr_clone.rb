#!/usr/bin/env ruby
# examples/tumblr_clone.rb
#
# a whole tumblr clone in one script. blogs, posts, follows, likes, tags,
# reblogs — every diamond feature pulling its weight.
#
# Run:   ruby examples/tumblr_clone.rb
#
# file-backed db on purpose: each Ractor opens its own connection, so the
# fan-out demo at the bottom needs a path they can all see. :memory: is
# per-connection and workers would get empty databases.

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'diamond'
require 'tempfile'

$failures = []
def check(desc, actual, expected)
  if actual == expected
    puts "  ok: #{desc}"
  else
    puts "  FAIL: #{desc}\n    expected #{expected.inspect}, got #{actual.inspect}"
    $failures << desc
  end
end

db_file = Tempfile.new(['tumblr', '.db'])
db_file.close
at_exit { db_file.unlink if db_file }

Diamond.wake_up(db_file.path)

# ----------------------------------------------------------------------
# schema. nothing fancy, just blogs and the stuff hanging off them.
# ----------------------------------------------------------------------

Diamond.define_relation(:blogs) do |t|
  t.attribute :id, Integer, primary_key: true, nullable: false
  t.attribute :name, String, nullable: false
  t.attribute :title, String
end

Diamond.define_relation(:posts) do |t|
  t.attribute :id, Integer, primary_key: true, nullable: false
  t.attribute :blog_id, Integer, nullable: false
  t.foreign_key :blog_id, :blogs, on_delete: :cascade
  t.attribute :kind, String, nullable: false   # text, photo, quote, ...
  t.attribute :body, String, nullable: false
  t.attribute :reblog_of_id, Integer           # null means original post
  t.foreign_key :reblog_of_id, :posts
  t.attribute :created_at, String, nullable: false
end

Diamond.define_relation(:follows) do |t|
  t.attribute :id, Integer, primary_key: true, nullable: false
  t.attribute :follower_id, Integer, nullable: false
  t.foreign_key :follower_id, :blogs, on_delete: :cascade
  t.attribute :followed_id, Integer, nullable: false
  t.foreign_key :followed_id, :blogs, on_delete: :cascade
end

Diamond.define_relation(:likes) do |t|
  t.attribute :id, Integer, primary_key: true, nullable: false
  t.attribute :blog_id, Integer, nullable: false
  t.foreign_key :blog_id, :blogs, on_delete: :cascade
  t.attribute :post_id, Integer, nullable: false
  t.foreign_key :post_id, :posts, on_delete: :cascade
end

Diamond.define_relation(:tags) do |t|
  t.attribute :id, Integer, primary_key: true, nullable: false
  t.attribute :post_id, Integer, nullable: false
  t.foreign_key :post_id, :posts, on_delete: :cascade
  t.attribute :tag, String, nullable: false
end

# ----------------------------------------------------------------------
# seed. three blogs, some posts, follows, likes, tags.
# ----------------------------------------------------------------------

arle = Blogs.create(id: 1, name: 'arle', title: 'puyo enjoyer')
carb = Blogs.create(id: 2, name: 'carbuncle', title: 'karbunkle noises')
sig = Blogs.create(id: 3, name: 'sig', title: 'bug enjoyer')

Posts.create(id: 10, blog_id: 2, kind: 'text', body: 'hello tumblr', created_at: '2026-09-01')
Posts.create(id: 11, blog_id: 2, kind: 'photo', body: 'my breakfast (beans)', created_at: '2026-09-02')
Posts.create(id: 12, blog_id: 3, kind: 'text', body: 'bugs are great actually', created_at: '2026-09-03')
Posts.create(id: 13, blog_id: 1, kind: 'text', body: 'reblogging the bean post', reblog_of_id: 11, created_at: '2026-09-04')
Posts.create(id: 14, blog_id: 3, kind: 'text', body: 'reblogging the reblog', reblog_of_id: 13, created_at: '2026-09-05')

Follows.create(id: 20, follower_id: 1, followed_id: 2)  # arle follows carbuncle
Follows.create(id: 21, follower_id: 1, followed_id: 3)  # arle follows sig

Likes.create(id: 30, blog_id: 1, post_id: 10)
Likes.create(id: 31, blog_id: 3, post_id: 10)
Likes.create(id: 32, blog_id: 1, post_id: 12)

Tags.create(id: 40, post_id: 10, tag: 'hello')
Tags.create(id: 41, post_id: 11, tag: 'beans')
Tags.create(id: 42, post_id: 12, tag: 'bugs')

puts "== seed =="
check("3 blogs", Blogs.count, 3)
check("5 posts", Posts.count, 5)

# ----------------------------------------------------------------------
# the dashboard. posts from blogs i follow, newest first, likes attached.
# one query: where_in for the follow graph, includes for the likes.
# ----------------------------------------------------------------------

puts "== dashboard =="
followed = Follows.where { follower_id == 1 }.derive(:followed_id)
dashboard = Posts.where_in(:blog_id, followed).includes(:likes).order(id: :desc).limit(10)
rows = dashboard.materialize
check("dashboard sees followed blogs' posts", rows.map(&:id).sort, [10, 11, 12, 14])
check("newest first", rows.first.id, 14)
beans = rows.find { |p| p.id == 11 }
check("eager likes ride along", beans.likes.size, 0)
hello = rows.find { |p| p.id == 10 }
check("liked post carries its likes", hello.likes.size, 2)
check("structs are frozen", hello.frozen?, true)

# ----------------------------------------------------------------------
# search. plain string goes straight through, regexp gets translated.
# ----------------------------------------------------------------------

puts "== search =="
check("string search", Posts.where { body =~ "%bean%" }.materialize.map(&:id), [11, 13])
check("regexp search", Posts.where { body =~ /^bugs/ }.materialize.map(&:id), [12])

# ----------------------------------------------------------------------
# trending. group posts by blog, keep the loud ones.
# (derive block and having block live on separate lines — the parser
# buckets blocks per line, so two blocks on one line collide.)
# ----------------------------------------------------------------------

puts "== trending =="
t = Posts.derive { blog_id; count(id) }.group(:blog_id)
t = t.having { count(id) > 1 }
loud = t.materialize
check("two loud blogs", loud.map(&:blog_id).sort, [2, 3])
check("two posts each", loud.map(&:count_id).uniq, [2])

# ----------------------------------------------------------------------
# reblog chains. recursive cte for the shape, then walk it in ruby.
# ----------------------------------------------------------------------

puts "== reblogs =="
base = Posts.where { id == 11 }
step = Posts.from_cte(:chain)
chain_q = Diamond.with_recursive(:chain, base, step)
sql, _ = Diamond::Compiler::Base.compile(chain_q.table, chain_q.ast)
check("recursive cte shape", sql.include?("WITH RECURSIVE chain AS"), true)
check("union all inside", sql.include?("UNION ALL"), true)

# the actual walk. reblog_of_id is just a self fk.
walked = []
cur = Posts.find(14).first
while cur
  walked << cur.id
  cur = cur.reblog_of_id ? Posts.find(cur.reblog_of_id).first : nil
end
check("reblog chain 14 -> 13 -> 11", walked, [14, 13, 11])

# ----------------------------------------------------------------------
# follow inside a transaction. second one raises on purpose to show
# the rollback.
# ----------------------------------------------------------------------

puts "== transactions =="
before = Follows.count
Diamond.transaction do
  Follows.create(id: 22, follower_id: 2, followed_id: 1)
end
check("follow committed", Follows.count, before + 1)

begin
  Diamond.transaction do
    Follows.create(id: 23, follower_id: 3, followed_id: 1)
    raise "notification service is down (it always is)"
  end
rescue RuntimeError
  # expected. the follow dies with the notification.
end
check("failed follow rolled back", Follows.count, before + 1)

# ----------------------------------------------------------------------
# edits and deletes. update speaks smalltalk, delete takes a where.
# ----------------------------------------------------------------------

puts "== edits =="
n = Posts.where { id == 12 }.update { body "bugs are still great actually" }
check("one row updated", n, 1)
check("edit stuck", Posts.find(12).body, "bugs are still great actually")

m = Posts.where { id == 14 }.delete
check("one row deleted", m, 1)
check("gone", Posts.where { id == 14 }.count, 0)

# ----------------------------------------------------------------------
# fan-out. one ractor per blog, each with its own connection, reading
# the same file at the same time. main just collects.
# ----------------------------------------------------------------------

puts "== ractor fan-out =="
# note: where-blocks can't see locals (block params parse as variable
# reads, not columns), so values cross into workers through find/create
# args. literals inside the block are fine.
workers = [1, 2, 3].map do |bid|
  Ractor.new(Blogs, bid) do |blogs, id|
    [blogs.find(id).name, Posts.where { kind == "text" }.count]
  end
end
got = workers.map(&:value)
check("every blog resolved from a worker", got.map(&:first).sort, %w[arle carbuncle sig])
check("workers counted text posts too", got.map(&:last).uniq, [3])

puts ""
if $failures.empty?
  puts "=== ALL DEMOS PASSED ==="
else
  puts "=== #{$failures.size} FAILURES ==="
  exit 1
end

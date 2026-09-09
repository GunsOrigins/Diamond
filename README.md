# Diamond

ruby ORM. blocks in, SQL out.

```ruby
Diamond.wake_up("tumblr.db")

Diamond.define_relation(:blogs) do |t|
  t.attribute :id, Integer, primary_key: true, nullable: false
  t.attribute :name, String, nullable: false
end

Diamond.define_relation(:posts) do |t|
  t.attribute :id, Integer, primary_key: true, nullable: false
  t.attribute :blog_id, Integer, nullable: false
  t.foreign_key :blog_id, :blogs, on_delete: :cascade
  t.attribute :body, String, nullable: false
end

# dashboard: posts from blogs i follow, likes attached, one query.
followed = Follows.where { follower_id == 1 }.derive(:followed_id)
Posts.where_in(:blog_id, followed).includes(:likes).order(id: :desc).limit(10).materialize
```

`examples/tumblr_clone.rb` is a tumblr clone in one file. run it.

## dsl

| you write | you get |
|---|---|
| `where { age > 10 }` | `WHERE age > ?`, bound param |
| `where { age >= 10 }` | `>=`, `<=` both work |
| `where { !(age == 10) }` | `NOT (...)`, `not` keyword too |
| `where { kind == :text }` | symbols bind as strings |
| `where { name == nil }` | `IS NULL` |
| `where { age.between?(16, 25) }` | `BETWEEN ? AND ?` |
| `where { name =~ /^A/ }` | `LIKE`, string or regexp |
| `q.where { a == 1 }` + `q.or { b == 2 }` | OR |
| `where_in(:id, Posts.derive(:user_id))` | `IN (SELECT ...)` |
| `includes(:posts, :comments)` | one query, nested structs back |
| `group(:blog_id).having { count(id) > 1 }` | GROUP BY / HAVING |
| `Diamond.transaction { ... }` | rollback on raise |
| `Diamond.with_recursive(...)` | recursive CTEs |
| `update { body "edited" }` | keyword update |

results are frozen structs. no save method — write through the table.
`pluck`, `count`, `exists?`, `first`, `last`, `each` all there.

## ractors

every ractor gets its own connection. tables are shareable constants so
workers resolve `Blogs` fine, they just open their own handle on first
query. reads parallelize, writes serialize.

```ruby
workers = [1, 2, 3].map do |id|
  Ractor.new(Blogs, id) do |blogs, bid|
    blogs.find(bid).name
  end
end
workers.map(&:value) # => ["arle", "carbuncle", "sig"]
```

`:memory:` is per-connection so workers get empty ones. use a file path
if ractors need the same data. where-blocks can't see locals either —
pass values through `find` args, keep literals in the block.

## limits

- one block per line. the parser buckets blocks by line, two on one line
  collide. normal formatting and you never hit it.
- filtering on joined columns needs `table.column` refs, join first:
  `Posts.join(:tags).where { tags.tag == 'x' }`. barewords still mean
  the base table.
- query objects aren't shareable. build them in the worker, ship
  structs back.
- operators registered after `wake_up` stay in main. workers get
  built-ins.

## extending

`EXTENDING.md`. operators hook prism -> AST -> SQL by priority,
~50 lines each. `lib/diamond/operators/like.rb` is the reference.

## hacking

```
rake            # test/ + spec/
ruby examples/tumblr_clone.rb
```

ruby 4.x, extralite ~> 3.0, prism.

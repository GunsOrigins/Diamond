require_relative 'lib/diamond/version' unless defined?(Diamond::VERSION)

Gem::Specification.new do |spec|
  spec.name        = "diamond"
  spec.version     = "0.1.0"
  spec.summary     = "A pure, AST-backed, lazy ORM."
  spec.description = "Diamond is a language for relational algebra with a Ruby syntax frontend and an SQLite C-level backend."
  spec.authors     = ["GunsOrigins"]
  spec.email       = "gunnchayut@gmail.com"
  spec.homepage    = "https://github.com/GunsOrigins/Diamond"
  spec.license     = "MIT"

  spec.files       = Dir["lib/**/*.rb"] + ["README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "extralite", "~> 3.0"
  spec.add_dependency "prism", "~> 0.17"

  spec.required_ruby_version = ">= 3.0.0"
end

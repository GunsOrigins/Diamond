require 'rake/testtask'

Rake::TestTask.new(:test) do |t|
  t.libs << 'lib'
  t.test_files = FileList['test/**/*_test.rb']
end

namespace :spec do
  desc 'Run Minitest::Spec suite'
  task :run do
    ruby '-Ilib', '-Ispec', 'spec/diamond_spec.rb'
  end
end

task default: [:test, 'spec:run']

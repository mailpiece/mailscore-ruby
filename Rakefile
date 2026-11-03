require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new do |t|
  t.libs << "test"
  t.pattern = "test/**/*_test.rb"
end

desc "Run RuboCop"
task :rubocop do
  sh "bundle exec rubocop"
end

task default: %i[ rubocop test ]

require_relative "lib/mailscore/client/version"

Gem::Specification.new do |spec|
  spec.name = "mailscore-ruby"
  spec.version = MailScore::Client::VERSION
  spec.platform = Gem::Platform::RUBY
  spec.required_ruby_version = ">= 3.4"
  spec.authors = [ "Simon Lev" ]

  spec.summary = "A thin Ruby client for mailscore's HTTP API."
  spec.description = "Check, learn and fuzzy-hash mail against a mailscore server over Net::HTTP, with no dependencies beyond Ruby's standard library."

  spec.homepage = "https://github.com/mailpiece/mailscore-ruby"
  spec.license = "MIT"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir[
    "lib/**/*.rb",
    "CHANGELOG.md",
    "README.md",
    "LICENSE",
    "mailscore-ruby.gemspec"
  ]
  spec.require_paths = [ "lib" ]
end

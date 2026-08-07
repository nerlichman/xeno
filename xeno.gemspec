require_relative "lib/xeno/version"

Gem::Specification.new do |spec|
  spec.name        = "xeno"
  spec.version     = Xeno::VERSION
  spec.authors     = [ "Nicolas Erlichman" ]
  spec.homepage    = "https://github.com/nerlichman/xeno"
  spec.summary     = "A framework for durable AI agents. Built on Rails."
  spec.description = "xeno is a framework for durable AI agents built on Rails, " \
                     "runnable standalone (xeno new my-agent) or inside the Rails app " \
                     "you already have. Sessions survive restarts and deploys mid-turn, " \
                     "wait days for a human approval without holding a process, and " \
                     "resume exactly where they stopped."
  spec.license     = "MIT"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,docs,exe,lib}/**/*", "LICENSE", "Rakefile", "README.md", "CHANGELOG.md"]
  end

  spec.bindir = "exe"
  spec.executables = [ "xeno" ]

  spec.required_ruby_version = ">= 3.2"

  spec.add_dependency "rails", ">= 8.0"
  spec.add_dependency "ruby_llm", ">= 1.16"
end

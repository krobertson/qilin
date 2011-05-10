# -*- encoding: utf-8 -*-
$:.push File.expand_path("../lib", __FILE__)
require "qilin/version"

Gem::Specification.new do |s|
  s.name        = "qilin"
  s.version     = Qilin::VERSION
  s.platform    = Gem::Platform::RUBY
  s.authors     = ["Ken Robertson"]
  s.email       = ["ken@invalidlogic.com"]
  s.homepage    = "http://github.com/krobertson/qilin"
  s.summary     = %q{A lightweight framework for background processing across many child threads, inspired heavily by Unicorn.}
  s.description = %q{A lightweight framework for background processing across many child threads, inspired heavily by Unicorn.}

  s.rubyforge_project = "qilin"

  s.executables   = %w(qilin)
  s.files         = `git ls-files`.split("\n")
  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
  s.require_paths = ["lib"]
end

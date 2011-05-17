# -*- encoding: utf-8 -*-
$:.push File.expand_path("../lib", __FILE__)
require "qilin/version"

Gem::Specification.new do |s|
  s.name        = "qilin"
  s.version     = Qilin::VERSION
  s.date        = '2011-05-16'
  s.platform    = Gem::Platform::RUBY
  s.authors     = ["Ken Robertson"]
  s.email       = ["ken@invalidlogic.com"]
  s.homepage    = "http://github.com/krobertson/qilin"
  s.summary     = %q{A lightweight framework for background processing across many child processes, inspired heavily by Unicorn.}
  s.description = %q{A lightweight framework for background processing across many child processes, inspired heavily by Unicorn.}

  s.rubyforge_project = "qilin"

  s.executables   = %w(qilin)

  s.files         = %w( Rakefile LICENSE )
  s.files         += Dir.glob("lib/**/*")
  s.files         += Dir.glob("bin/**/*")
  s.require_paths = ["lib"]
end

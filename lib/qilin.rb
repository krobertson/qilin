module Qilin
  def self.run(options = {})
    Qilin::Manager.new(options).start.join
  end
end

require 'fcntl'

require 'qilin/version'
require 'qilin/manager'
require 'qilin/worker'
require 'qilin/configurator'
require 'qilin/tmpio'

$LOAD_PATH << File.join(File.dirname(__FILE__), '..', 'lib')

require 'qilin'

a = Qilin::Manager.new(:config_file => File.join(File.dirname(__FILE__), 'example_config.rb'))
a.start
a.join
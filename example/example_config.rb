worker_processes 10
working_directory File.join(File.dirname(__FILE__), '..')
timeout 8
pid File.join(File.dirname(__FILE__), "qilin.pid")
preload_app true

# http://www.rubyenterpriseedition.com/faq.html#adapt_apps_for_cow
if GC.respond_to?(:copy_on_write_friendly=)
  GC.copy_on_write_friendly = true
end

before_fork do |parent, worker|
  # the following is highly recomended for Rails + "preload_app true"
  # as there's no need for the master process to hold a connection
  defined?(ActiveRecord::Base) and
    ActiveRecord::Base.connection.disconnect!
end

after_fork do |parent, worker|
  ##
  # Unicorn master loads the app then forks off workers - because of the way
  # Unix forking works, we need to make sure we aren't using any of the parent's
  # sockets, e.g. db connection
  
  # Redis and Memcached would go here but their connections are established
  # on demand, so the master never opens a socket

  # the following is *required* for Rails + "preload_app true",
  defined?(ActiveRecord::Base) and
    ActiveRecord::Base.establish_connection
end

pull_job do |parent|
  Time.now.to_s
end

process_job do |worker,job_payload|
  time = (rand*10).to_i
  puts "worker#{worker.nr}: #{job_payload} - sleeping #{time}"
  sleep time
  true
end

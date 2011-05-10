# -*- encoding: binary -*-
require 'logger'

# Implements a simple DSL for configuring a Qilin server.
#
# See http://unicorn.bogomips.org/examples/unicorn.conf.rb and
# http://unicorn.bogomips.org/examples/unicorn.conf.minimal.rb
# example configuration files.  An example config file for use with
# nginx is also available at
# http://unicorn.bogomips.org/examples/nginx.conf
class Qilin::Configurator
  include Qilin

  # :stopdoc:
  attr_accessor :set, :config_file

  # Default settings for Qilin
  DEFAULTS = {
    :timeout => 300,
    :logger => Logger.new($stderr),
    :worker_processes => 1,
    :after_fork => lambda { |parent, worker|
        parent.logger.info("worker=#{worker.nr} spawned pid=#{$$}")
      },
    :before_fork => lambda { |parent, worker|
        parent.logger.info("worker=#{worker.nr} spawning...")
      },
    :pid => nil,
    :preload_app => false
  }
  #:startdoc:

  def initialize(defaults = {}) #:nodoc:
    self.set = Hash.new(:unset)
    @use_defaults = defaults.delete(:use_defaults)
    self.config_file = defaults.delete(:config_file)

    set.merge!(DEFAULTS) if @use_defaults
    defaults.each { |key, value| self.__send__(key, value) }
    reload(false)
  end

  def reload(merge_defaults = true) #:nodoc:
    if merge_defaults && @use_defaults
      set.merge!(DEFAULTS) if @use_defaults
    end
    instance_eval(File.read(config_file), config_file) if config_file

    # working_directory binds immediately (easier error checking that way),
    # now ensure any paths we changed are correctly set.
    [ :pid, :stderr_path, :stdout_path ].each do |var|
      String === (path = set[var]) or next
      path = File.expand_path(path)
      File.writable?(path) || File.writable?(File.dirname(path)) or \
            raise ArgumentError, "directory for #{var}=#{path} not writable"
    end
  end

  def commit!(parent, options = {}) #:nodoc:
    skip = options[:skip] || []
    set.each do |key, value|
      value == :unset and next
      skip.include?(key) and next
      parent.__send__("#{key}=", value)
    end
  end

  def [](key) # :nodoc:
    set[key]
  end

  # sets object to the +new+ Logger-like object.  The new logger-like
  # object must respond to the following methods:
  #  +debug+, +info+, +warn+, +error+, +fatal+
  # The default Logger will log its output to the path specified
  # by +stderr_path+.  If you're running Qilin daemonized, then
  # you must specify a path to prevent error messages from going
  # to /dev/null.
  def logger(new)
    %w(debug info warn error fatal).each do |m|
      new.respond_to?(m) and next
      raise ArgumentError, "logger=#{new} does not respond to method=#{m}"
    end

    set[:logger] = new
  end

  # sets after_fork hook to a given block.  This block will be called by
  # the worker after forking.  The following is an example hook which adds
  # a per-process listener to every worker:
  #
  #  after_fork do |parent,worker|
  #    # drop permissions to "www-data" in the worker
  #    # generally there's no reason to start Qilin as a priviledged user
  #    # as it is not recommended to expose Qilin to public clients.
  #    worker.user('www-data', 'www-data') if Process.euid == 0
  #  end
  def after_fork(*args, &block)
    set_hook(:after_fork, block_given? ? block : args[0])
  end

  # sets before_fork got be a given Proc object.  This Proc
  # object will be called by the master process before forking
  # each worker.
  def before_fork(*args, &block)
    set_hook(:before_fork, block_given? ? block : args[0])
  end

  # TODO
  def pull_job(*args, &block)
    set_hook(:pull_job, block_given? ? block : args[0], 1)
  end

  # TODO
  def process_job(*args, &block)
    set_hook(:process_job, block_given? ? block : args[0])
  end

  # sets the timeout of worker processes to +seconds+.  Workers
  # handling the request/app.call/response cycle taking longer than
  # this time period will be forcibly killed (via SIGKILL).  This
  # timeout is enforced by the master process itself and not subject
  # to the scheduling limitations by the worker process.  Due the
  # low-complexity, low-overhead implementation, timeouts of less
  # than 3.0 seconds can be considered inaccurate and unsafe.
  def timeout(seconds)
    set_int(:timeout, seconds, 3)
  end

  # sets the current number of worker_processes to +nr+.  Each worker
  # process will serve exactly one client at a time.  You can
  # increment or decrement this value at runtime by sending SIGTTIN
  # or SIGTTOU respectively to the master process without reloading
  # the rest of your Qilin configuration.  See the SIGNALS document
  # for more information.
  def worker_processes(nr)
    set_int(:worker_processes, nr, 1)
  end

  # sets the +path+ for the PID file of the Qilin master process
  def pid(path); set_path(:pid, path); end

  # Enabling this preloads an application before forking worker
  # processes.  This allows memory savings when using a
  # copy-on-write-friendly GC but can cause bad things to happen when
  # resources like sockets are opened at load time by the master
  # process and shared by multiple children.  People enabling this are
  # highly encouraged to look at the before_fork/after_fork hooks to
  # properly close/reopen sockets.  Files opened for logging do not
  # have to be reopened as (unbuffered-in-userspace) files opened with
  # the File::APPEND flag are written to atomically on UNIX.
  #
  # In addition to reloading the Qilin-specific config settings,
  # SIGHUP will reload application code in the working
  # directory/symlink when workers are gracefully restarted when
  # preload_app=false (the default).  As reloading the application
  # sometimes requires RubyGems updates, +Gem.refresh+ is always
  # called before the application is loaded (for RubyGems users).
  #
  # During deployments, care should _always_ be taken to ensure your
  # applications are properly deployed and running.  Using
  # preload_app=false (the default) means you _must_ check if
  # your application is responding properly after a deployment.
  # Improperly deployed applications can go into a spawn loop
  # if the application fails to load.  While your children are
  # in a spawn loop, it is is possible to fix an application
  # by properly deploying all required code and dependencies.
  # Using preload_app=true means any application load error will
  # cause the master process to exit with an error.
  def preload_app(bool)
    set_bool(:preload_app, bool)
  end

  # Allow redirecting $stderr to a given path.  Unlike doing this from
  # the shell, this allows the Qilin process to know the path its
  # writing to and rotate the file if it is used for logging.  The
  # file will be opened with the File::APPEND flag and writes
  # synchronized to the kernel (but not necessarily to _disk_) so
  # multiple processes can safely append to it.
  #
  # If you are daemonizing and using the default +logger+, it is important
  # to specify this as errors will otherwise be lost to /dev/null.
  # Some applications/libraries may also triggering warnings that go to
  # stderr, and they will end up here.
  def stderr_path(path)
    set_path(:stderr_path, path)
  end

  # Same as stderr_path, except for $stdout.  Not many Rack applications
  # write to $stdout, but any that do will have their output written here.
  # It is safe to point this to the same location a stderr_path.
  # Like stderr_path, this defaults to /dev/null when daemonized.
  def stdout_path(path)
    set_path(:stdout_path, path)
  end

  # sets the working directory for Qilin.
  def working_directory(path)
    # just let chdir raise errors
    path = File.expand_path(path)
    if config_file &&
       config_file[0] != ?/ &&
       ! File.readable?("#{path}/#{config_file}")
      raise ArgumentError,
            "config_file=#{config_file} would not be accessible in" \
            " working_directory=#{path}"
    end
    Dir.chdir(path)
    # TODO Sockets::Center::START_CTX[:cwd] = ENV["PWD"] = path
  end

  # Runs worker processes as the specified +user+ and +group+.
  # The master process always stays running as the user who started it.
  # This switch will occur after calling the after_fork hook, and only
  # if the Worker#user method is not called in the after_fork hook
  def user(user, group = nil)
    # raises ArgumentError on invalid user/group
    Etc.getpwnam(user)
    Etc.getgrnam(group) if group
    set[:user] = [ user, group ]
  end

private
  def set_int(var, n, min) #:nodoc:
    Integer === n or raise ArgumentError, "not an integer: #{var}=#{n.inspect}"
    n >= min or raise ArgumentError, "too low (< #{min}): #{var}=#{n.inspect}"
    set[var] = n
  end

  def set_path(var, path) #:nodoc:
    case path
    when NilClass, String
      set[var] = path
    else
      raise ArgumentError
    end
  end

  def set_bool(var, bool) #:nodoc:
    case bool
    when true, false
      set[var] = bool
    else
      raise ArgumentError, "#{var}=#{bool.inspect} not a boolean"
    end
  end

  def set_hook(var, my_proc, req_arity = 2) #:nodoc:
    case my_proc
    when Proc
      arity = my_proc.arity
      (arity == req_arity) or \
        raise ArgumentError,
              "#{var}=#{my_proc.inspect} has invalid arity: " \
              "#{arity} (need #{req_arity})"
    when NilClass
      my_proc = DEFAULTS[var]
    else
      raise ArgumentError, "invalid type: #{var}=#{my_proc.inspect}"
    end
    set[var] = my_proc
  end
end

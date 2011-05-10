class Qilin::Manager
  attr_accessor :timeout, :worker_processes,
                :before_fork, :after_fork,
                :preload_app, :pull_job, :process_job,
                :master_pid, :config, :user
  attr_reader :pid, :logger

  CHILD_READY = []
  CHILD_PIPES = {}

  # signal queue used for self-piping
  SIG_QUEUE = []

  # This hash maps PIDs to Workers
  WORKERS = {}

  # general
  def logger=(obj)
    @logger = obj
  end

  # sets the path for the PID file of the master process
  def pid=(path)
    if path
      if x = valid_pid?(path)
        return path if pid && path == pid && x == $$
        raise ArgumentError, "Already running on PID:#{x} " \
                             "(or pid=#{path} is stale)"
      end
    end
    unlink_pid_safe(pid) if pid

    if path
      fp = begin
        tmp = "#{File.dirname(path)}/#{rand}.#$$"
        File.open(tmp, File::RDWR|File::CREAT|File::EXCL, 0644)
      rescue Errno::EEXIST
        retry
      end
      fp.syswrite("#$$\n")
      File.rename(fp.path, path)
      fp.close
    end
    @pid = path
  end

  # unlinks a PID file at given +path+ if it contains the current PID
  # still potentially racy without locking the directory (which is
  # non-portable and may interact badly with other programs), but the
  # window for hitting the race condition is small
  def unlink_pid_safe(path)
    (File.read(path).to_i == $$ and File.unlink(path)) rescue nil
  end

  # returns a PID if a given path contains a non-stale PID file,
  # nil otherwise.
  def valid_pid?(path)
    wpid = File.read(path).to_i
    wpid <= 0 and return
    Process.kill(0, wpid)
    wpid
    rescue Errno::ESRCH, Errno::ENOENT
      # don't unlink stale pid files, racy without non-portable locking...
  end

  def initialize(app, options = {})
    options = options.dup
    options[:use_defaults] = true
    self.config = Qilin::Configurator.new(options)
    config.commit!(self, :skip => [:pid])
  end

  # Runs the thing.  Returns self so you can run join on it
  def start
    self.pid = config[:pid]
    self.master_pid = $$

    build_app! if preload_app
    maintain_worker_count
    self
  end

  # monitors children and receives signals forever
  # (or until a termination signal is sent).  This handles signals
  # one-at-a-time time and we'll happily drop signals in case somebody
  # is signalling us too often.
  def join
    respawn = true
    last_check = Time.now

    proc_name 'master'
    logger.info "master process ready" # test_exec.rb relies on this message
    begin
      reap_all_workers
      case SIG_QUEUE.shift
      when nil
        # avoid murdering workers after our master process (or the
        # machine) comes out of suspend/hibernation
        if (last_check + @timeout) >= (last_check = Time.now)
          murder_lazy_workers
        end
        sleep_time = 1 # TODO make configurable
        maintain_worker_count if respawn
        master_poll(sleep_time)
      when :QUIT # graceful shutdown
        break
      when :TERM, :INT # immediate shutdown
        stop(false)
        break
      when :USR1 # rotate logs
        logger.info "master reopening logs..."
        # TODO Unicorn::Util.reopen_logs
        logger.info "master done reopening logs"
        kill_each_worker(:USR1)
      when :WINCH
        if Process.ppid == 1 || Process.getpgrp != $$
          respawn = false
          logger.info "gracefully stopping all workers"
          kill_each_worker(:QUIT)
          self.worker_processes = 0
        else
          logger.info "SIGWINCH ignored because we're not daemonized"
        end
      when :TTIN
        respawn = true
        self.worker_processes += 1
      when :TTOU
        self.worker_processes -= 1 if self.worker_processes > 0
      when :HUP
        respawn = true
        if config.config_file
          load_config!
        else # exec binary and exit if there's no config file
          logger.info "config_file not present, reexecuting binary"
          reexec
        end
      end
    rescue Errno::EINTR
    rescue => e
      logger.error "Unhandled master loop exception #{e.inspect}."
      logger.error e.backtrace.join("\n")
    end while true
    stop # gracefully shutdown all workers on our way out
    logger.info "master complete"
    unlink_pid_safe(pid) if pid
  end

  # wait for a signal hander to wake us up and then consume the pipe
  def master_poll(sec)
    r = IO.select(CHILD_READY, nil, nil, sec) or return false
    rd = r.flatten.first
    return false unless rd

    begin
      rd.gets
      ready_child = CHILD_PIPES[rd]
      return false unless ready_child

      job = pull_job.call(self)
      ready_child.puts(job) if job
    rescue Exception => e
      logger.error "Unhandled master poll exception: #{e.inspect}"
      logger.error e.backtrace.join("\n")
    end
  end

  # Terminates all workers, but does not exit master process
  def stop(graceful = true)
    limit = Time.now + timeout
    until WORKERS.empty? || Time.now > limit
      kill_each_worker(graceful ? :QUIT : :TERM)
      sleep(0.1)
      reap_all_workers
    end
    kill_each_worker(:KILL)
  end

  def load_config!
    logger.info "reloading config_file=#{config.config_file}"
    config.reload
    config.commit!(self)
    kill_each_worker(:QUIT)
    # TODO Unicorn::Util.reopen_logs
    logger.info "done reloading config_file=#{config.config_file}"
  rescue StandardError, LoadError, SyntaxError => e
    logger.error "error reloading config_file=#{config.config_file}: " \
                 "#{e.class} #{e.message} #{e.backtrace}"
  end

  private

  def spawn_missing_workers
    (0...worker_processes).each do |worker_nr|
      WORKERS.values.include?(worker_nr) and next
      worker = Qilin::Worker.new(worker_nr, Qilin::TmpIO.new)
      spawn_worker(worker)
    end
  end

  def spawn_worker(worker)
    before_fork.call(self, worker)

    # Used by the worker to tell the manager its ready for a job
    read_ready, write_ready = IO.pipe

    # Used by the manager to pass a job to the worker
    read_job, write_job = IO.pipe

    # set it on the worker
    worker.ready_pipe = [read_ready, write_ready]
    worker.job_pipe = [read_job, write_job]

    # Fork the worker
    WORKERS[fork {
      worker_loop(worker)
    }] = worker

    CHILD_READY << read_ready
    CHILD_PIPES[read_ready] = write_job
  end

  def maintain_worker_count
    (off = WORKERS.size - worker_processes) == 0 and return
    off < 0 and return spawn_missing_workers
    WORKERS.dup.each_pair { |wpid,w|
      w.nr >= worker_processes and kill_worker(:QUIT, wpid) rescue nil
    }
  end

  # gets rid of stuff the worker has no business keeping track of
  # to free some resources and drops all sig handlers.
  # traps for USR1, USR2, and HUP may be set in the after_fork Proc
  # by the user.
  def init_worker_process(worker)
    # TODO QUEUE_SIGS.each { |sig| trap(sig, nil) }
    trap(:CHLD, 'DEFAULT')
    SIG_QUEUE.clear
    proc_name "worker[#{worker.nr}]"
    WORKERS.values.each { |other| other.tmp.close rescue nil }
    WORKERS.clear
    worker.tmp.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC)
    after_fork.call(self, worker) # can drop perms
    worker.user(*user) if user.kind_of?(Array) && ! worker.switched
    self.timeout /= 2.0 # halve it for select()
    build_app! unless preload_app
  end

  def reopen_worker_logs(worker_nr)
    logger.info "worker=#{worker_nr} reopening logs..."
    # TODO Unicorn::Util.reopen_logs
    logger.info "worker=#{worker_nr} done reopening logs"
  end

  # runs inside each forked worker, this sits around and waits
  # for connections and doesn't die until the parent dies (or is
  # given a INT, QUIT, or TERM signal)
  def worker_loop(worker)
    ppid = master_pid
    init_worker_process(worker)
    nr = 0 # this becomes negative if we need to reopen logs
    alive = worker.tmp # tmp is our lifeline to the master process

    # closing anything we IO.select on will raise EBADF
    trap(:USR1) { nr = -65536; worker.job_pipe[0].close rescue nil }
    trap(:QUIT) { alive = nil; }
    [:TERM, :INT].each { |sig| trap(sig) { exit!(0) } } # instant shutdown
    logger.info "worker=#{worker.nr} ready"
    m = 0

    begin
      nr < 0 and reopen_worker_logs(worker.nr)
      nr = 0

      # we're a goner in timeout seconds anyways if alive.chmod
      # breaks, so don't trap the exception.  Using fchmod() since
      # futimes() is not available in base Ruby and I very strongly
      # prefer temporary files to be unlinked for security,
      # performance and reliability reasons, so utime is out.  No-op
      # changes with chmod doesn't update ctime on all filesystems; so
      # we change our counter each and every time (after process_client
      # and before IO.select).
      alive.chmod(m = 0 == m ? 1 : 0)

      # Signal to the manager we're ready for a job
      worker.ready_pipe[1].puts('.')

      # Read a job from the manager
      job_payload = worker.job_pipe[0].gets.chomp

      # timestamp
      alive.chmod(m = 0 == m ? 1 : 0)

      # process the job payload
      process_job.call(worker, job_payload)

      # make the following bet: if we accepted clients this round,
      # we're probably reasonably busy, so avoid calling select()
      # and do a speculative non-blocking accept() on ready listeners
      # before we sleep again in select().
      redo unless nr == 0 # (nr < 0) => reopen logs

      ppid == Process.ppid or return
      alive.chmod(m = 0 == m ? 1 : 0)
    rescue => e
      if alive
        logger.error "Unhandled listen loop exception #{e.inspect}."
        logger.error e.backtrace.join("\n")
      end
    end while alive
  end

  # forcibly terminate all workers that haven't checked in in timeout
  # seconds.  The timeout is implemented using an unlinked File
  # shared between the parent process and each worker.  The worker
  # runs File#chmod to modify the ctime of the File.  If the ctime
  # is stale for >timeout seconds, then we'll kill the corresponding
  # worker.
  def murder_lazy_workers
    t = @timeout
    WORKERS.dup.each_pair do |wpid, worker|
      stat = worker.tmp.stat
      # skip workers that disable fchmod or have never fchmod-ed
      stat.mode == 0100600 and next
      diff = Time.now - stat.ctime
      next if diff <= t
      logger.error "worker=#{worker.nr} PID:#{wpid} timeout " \
                   "(#{diff}s > #{t}s), killing"
      kill_worker(:KILL, wpid) # take no prisoners for timeout violations
    end
  end

  # reaps all unreaped workers
  def reap_all_workers
    begin
      wpid, status = Process.waitpid2(-1, Process::WNOHANG)
      wpid or return
      worker = WORKERS.delete(wpid) and worker.tmp.close rescue nil
      CHILD_READY.delete(worker.ready_pipe[0]) and CHILD_PIPES.delete(worker.ready_pipe[0]) and worker.ready_pipe.map(&:close) and worker.job_pipe.map(&:close) rescue nil
      m = "reaped #{status.inspect} worker=#{worker.nr rescue 'unknown'}"
      status.success? ? logger.info(m) : logger.error(m)
    rescue Errno::ECHILD
      break
    end while true
  end

  # delivers a signal to a worker and fails gracefully if the worker
  # is no longer running.
  def kill_worker(signal, wpid)
    Process.kill(signal, wpid)
    rescue Errno::ESRCH
      worker = WORKERS.delete(wpid) and worker.tmp.close rescue nil
  end

  # delivers a signal to each worker
  def kill_each_worker(signal)
    WORKERS.keys.each { |wpid| kill_worker(signal, wpid) }
  end

  def build_app!
    # TODO
    #if app.respond_to?(:arity) && app.arity == 0
    #  if defined?(Gem) && Gem.respond_to?(:refresh)
    #    logger.info "Refreshing Gem list"
    #    Gem.refresh
    #  end
    #  self.app = app.call
    #end
  end








  def proc_name(tag)
    $0 = "qilin_#{tag}"
  end

end

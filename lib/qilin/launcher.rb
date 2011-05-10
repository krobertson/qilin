# -*- encoding: binary -*-

$stdout.sync = $stderr.sync = true
$stdin.binmode
$stdout.binmode
$stderr.binmode

require 'qilin'

module Qilin::Launcher

  # We don't do a lot of standard daemonization stuff:
  #   * umask is whatever was set by the parent process at startup
  #     and can be set in config.ru and config_file, so making it
  #     0000 and potentially exposing sensitive log data can be bad
  #     policy.
  #   * don't bother to chdir("/") here since qilin is designed to
  #     run inside APP_ROOT.  Qilin will also re-chdir() to
  #     the directory it was started in when being re-executed
  #     to pickup code changes if the original deployment directory
  #     is a symlink or otherwise got replaced.
  def self.daemonize!(options)
    cfg = Qilin::Configurator
    $stdin.reopen("/dev/null")

    # grandparent - reads pipe, exits when master is ready
    #  \_ parent  - exits immediately ASAP
    #      \_ qilin manager - writes to pipe when ready

    rd, wr = IO.pipe
    grandparent = $$
    if fork
      wr.close # grandparent does not write
    else
      rd.close # qilin master does not read
      Process.setsid
      exit if fork # parent dies now
    end

    if grandparent == $$
      # this will block until Manager#join runs (or it dies)
      master_pid = (rd.readpartial(16) rescue nil).to_i
      unless master_pid > 1
        warn "master failed to start, check stderr log for details"
        exit!(1)
      end
      exit 0
    else # qilin master process
      options[:ready_pipe] = wr
    end

    # $stderr/$stderr can/will be redirected separately in the qilin config
    cfg::DEFAULTS[:stderr_path] ||= "/dev/null"
    cfg::DEFAULTS[:stdout_path] ||= "/dev/null"
  end

end

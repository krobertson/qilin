Qilin
=====

Qilin applies the principles used in [Unicorn](http://unicorn.bogomips.org/) but for background processing.  Unicorn is an excellent application server and robust with self managing its worker processes.  It supports lightweight forking, quickly respawning worker processes that die, and reaping processes that exceed a processing timeout.  The same attributes can be highly desirable with a high throughput tier.

Qilin is not a framework for background processing like [Resque](https://github.com/defunkt/resque) or [Delayed::Job](https://github.com/tobi/delayed_job/). Instead, it is meant to be more like a background processing container which leverages another framework for handling the queuing.  Eventually, the goal is for Qilin to work with Resque, Delayed::Job, and others.

Qilin is currently being groomed for production use at [Involver](http://involver.com/), where we perform several million background tasks per day and need a very resilient framework for managing our worker tier.

Qilin borrows heavily from Unicorn itself to lend itself a very similar configuration DSL and similar process and signal handling.  As such, it is released under GPL v2.

The name comes from the [mythical Chinese creature](http://en.wikipedia.org/wiki/Qilin) which is often referred to as the "Chinese unicorn".

Overview
--------

Qilin focuses on a processing model where a single master process is responsible for retrieving jobs to be processed and managing all of the worker processes.  It is referred to as the manager process.  If a worker process exits, it will respawn it.  If a worker exceeds its timeout processing a job, it will kill it and spawn another.

The way the manager process pulls a job for processing is defined using in a block and it is expected to return a string payload (object support coming soon) or nil if no job is available.  Requests to pull jobs are not expected to be blocking.  It should only check if one is available or return if not.

The worker processes focus on processing the payload from the manager.  A timeout is defined in the configuration with is intended to be a maximum time threshold a given job should take.  If it exceeds the timeout, it will kill the process and spawn another.  The payload is no re-attempted.  Soon, a hook will be provided so you can do reporting or accounting of timed out payloads.

Configuration
-------------

Qilin uses a very simple DSL for defining configuration options.  If you have used Unicorn before, it will look very familiar.

``` ruby
worker_processes 10
working_directory '/www/app/current'
timeout 60 # 1 minute
pid '/www/app/shared/pids/qilin.pid'
preload_app true

# How to load the app
load_app do
  require 'config/boot'
  require 'config/environment'
end

# The "job" is just a timestamp it'll puts
pull_job do |parent|
  Time.now.to_s
end

# Print the timestamp, then sleep a random amount of time from 1-10 seconds.
# Note the timeout is 8 seconds, just to demostrate how it'll reap workers
process_job do |worker,job_payload|
  time = (rand*10).to_i
  puts "worker#{worker.nr}: #{job_payload} - sleeping #{time}"
  sleep time
  true
end
```

Example configuration files are provided in the `example` directory.

Usage
-----

Installing Qilin can be done from the RubyGems:

    $ gem install qilin

To launch the Qilin process, can use the following:

    $ qilin -E production -c config/qilin.rb -D

This will load the `config/qilin.rb` configuration process, set the environment to production, and daemonize itself.

Command line options include:

```
Usage: qilin [ruby options] [qilin options]
Ruby options:
  -e, --eval LINE          evaluate a LINE of code
  -d, --debug              set debugging flags (set $DEBUG to true)
  -w, --warn               turn warnings on for your script
  -I, --include PATH       specify $LOAD_PATH (may be used more than once)
  -r, --require LIBRARY    require the library, before executing your script
qilin options:
  -E, --env RACK_ENV       use RACK_ENV for defaults (default: development)
  -D, --daemonize          run daemonized in the background

  -c, --config-file FILE   Qilin-specific config file
Common options:
  -h, --help               Show this message
  -v, --version            Show version
```

Signals
-------

The Qilin manager process responds the the following signals:

* `QUIT` - Graceful shutdown.  Wait for workers to finish processing and shutdown.
* `TERM` / `INT` - Immediately shutdown.  Kills all workers and exits.
* `HUP` - Reloads the configuration file and applies it.
* `USR1` - Rotate logs.
* `WINCH` - Gracefully kills all workers and doesn't respawn them.
* `TTIN` - Spawns an additional worker processes.
* `TTOU` - Reduces the worker count by one and gracefully kills an existing worker.

The Qilin worker processes respond to the following signals:

* `QUIT` - Gracefully shuts down after processing the current job.
* `TERM` / `INT` - Immediately shuts down.

Credit
------

Ken Robertson
All of the [Unicorn Contributors](http://unicorn.bogomips.org/CONTRIBUTORS.html) for giving us Unicorn.
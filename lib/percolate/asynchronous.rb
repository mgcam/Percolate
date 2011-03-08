#--
#
# Copyright (C) 2010 Genome Research Ltd. All rights reserved.
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

module Percolate
  class Asynchronizer
    attr_accessor :async_wrapper

    def initialize
      @async_wrapper = 'percolate-wrap'
    end

    def async_command task_id, command, work_dir, log, args = {}
    end

    def async_task name, args, command, env, procs = {}
    end

    def async_queues
      # TODO: remove this
      []
    end
  end

  class SystemAsynchronizer < Asynchronizer
    include Percolate

    def async_command task_id, command, work_dir, log, args = {}
      cmd_str = "#{self.async_wrapper} --host #{Asynchronous.message_host} " +
      "--port #{Asynchronous.message_port} " +
      "--queue #{Asynchronous.message_queue} " +
      "--task #{task_id}"

      Percolate.cd(work_dir, "#{cmd_str} -- #{command}")
    end

    def async_task fname, args, command, env, procs = {}
      having, confirm, yielding = ensure_procs(procs)
      memos = Percolate.memoizer.async_method_memos(fname)
      result = memos[args]
      submitted = result && result.submitted?

      log = Percolate.log
      log.debug("Entering task #{fname}")

      if submitted # Job was submitted
        log.debug("#{fname} system job '#{command}' is already queued")

        if result.value? # if queued, result is not nil, see above
          log.debug("Returning memoized #{fname} result: #{result}")
        else
          begin
            if result.failed?
              raise PercolateAsyncTaskError,
                    "#{fname} args: #{args.inspect} failed"
            elsif result.finished? &&
            confirm.call(*args.take(confirm.arity.abs))
              result.finished!(yielding.call(*args.take(yielding.arity.abs)))
              log.debug("Postconditions for #{fname} satsified; " +
                        "returning #{result}")
            else
              log.debug("Postconditions for #{fname} not satsified; " +
                        "returning nil")
            end
          rescue PercolateAsyncTaskError => pate
            # Any of the having, confirm or yielding procs may throw this
            log.error("#{fname} requires attention: #{pate.message}")
            raise pate
          end
        end
      else # Can we submit the system job?
        if !having.call(*args.take(having.arity.abs))
          log.debug("Preconditions for #{fname} not satisfied; " +
                    "returning nil")
        else
          log.debug("Preconditions for #{fname} satisfied; " +
                    "submitting '#{command}'")

          if submit_async(fname, command)
            task_id = Percolate.task_identity(fname, args)
            submission_time = Time.now
            memos[args] = Result.new(fname, task_id, submission_time)
          end
        end
      end

      result
    end

    def submit_async fname, command
      # Check that the message queue has been set
      unless Asynchronous.message_queue
        raise PercolateError, "No message queue has been provided"
      end

      # Jump through hoops because bsub insists on polluting our stdout
      # TODO: pass environment variables from env
      status, stdout = system_command("#{command} &")
      success = command_success?(status)

      Percolate.log.info("submission reported #{stdout} for #{fname}")

      case
        when status.signaled?
          raise PercolateAsyncTaskError,
                "Uncaught signal #{status.termsig} from '#{command}'"
        when !success
          raise PercolateAsyncTaskError,
                "Non-zero exit #{status.exitstatus} from '#{command}'"
        else
          Percolate.log.debug("#{fname} async job '#{command}' is submitted, " +
                              "meanwhile returning nil")
      end

      success
       end
  end

  class LSFAsynchronizer < Asynchronizer
    include Percolate

    attr_reader :async_submitter
    attr_accessor :async_queues

    def initialize async_queues = [:yesterday, :small, :normal, :long, :basement]
      super()
      @async_queues = async_queues
      @async_submitter = 'bsub'
    end

    # Wraps a command String in an LSF job submission command.
    #
    # Arguments:
    #
    # - task_id (String): a task identifier.
    # - command (String): The command to be executed on the batch queue.
    # - log (String): The path of the LSF log file to be created.
    # - args (Hash): Various arguments to LSF:
    #   - :queue     => LSF queue (Symbol) e.g. :normal, :long
    #   - :memory    => LSF memory limit in Mb (Fixnum)
    #   - :depend    => LSF job dependency (String)
    #   - :select    => LSF resource select options (String)
    #   - :reserve   => LSF resource rusage options (String)
    #   - :size      => LSF job array size (Fixnum)
    #
    # Returns:
    #
    # - String
    #
    def async_command task_id, command, work_dir, log, args = {}
      defaults = {:queue => :normal,
                  :memory => 1900,
                  :cpus => 1,
                  :depend => nil,
                  :select => nil,
                  :reserve => nil,
                  :array_file => nil}
      args = defaults.merge(args)

      queue, mem, cpus, depend, select, reserve, uid =
      args[:queue], args[:memory], args[:cpus], '', '', '', $$

      unless @async_queues.include?(queue)
        raise ArgumentError, ":queue must be one of #{@async_queues.inspect}"
      end
      unless mem.is_a?(Fixnum) && mem > 0
        raise ArgumentError, ":memory must be a positive Fixnum"
      end
      unless cpus.is_a?(Fixnum) && cpus > 0
        raise ArgumentError, ":cpus must be a positive Fixnum"
      end
      if command && args[:array_file]
        raise ArgumentError,
              "Both a single command and a command array file were supplied"
      end

      if args[:select]
        select = " && #{args[:select]}"
      end
      if args[:reserve]
        reserve = ":#{args[:reserve]}"
      end
      if args[:depend]
        depend = " -w #{args[:depend]}"
      end

      cpu_str = nil
      if args[:cpus] > 1
        cpu_str = "-n #{args[:cpus]} -R 'span[hosts=1]'"
      end

      cmd_str = "#{self.async_wrapper} --host #{Asynchronous.message_host} " +
      "--port #{Asynchronous.message_port} " +
      "--queue #{Asynchronous.message_queue} " +
      "--task #{task_id}"

      job_name = "#{task_id}.#{uid}"
      if args[:array_file]
        # In a job array the actual command is pulled from the job's
        # command array file using the LSF job index
        size = count_lines(args[:array_file])
        job_name << "[1-#{size}]"
        cmd_str << ' --index'
      else
        # Otherwise the command is run directly
        cmd_str << " -- '#{command}'"
      end

      Percolate.cd(work_dir,
                   "#{self.async_submitter} -J '#{job_name}' -q #{queue} " +
                   "-R 'select[mem>#{mem}#{select}] " +
                   "rusage[mem=#{mem}#{reserve}]'#{depend} " +
                   "#{cpu_str} " +
                   "-M #{mem * 1000} -oo #{log} #{cmd_str}")
    end

    # Run or update a memoized batch command having pre- and
    # post-conditions.
    def async_task fname, args, command, env, procs = {}
      having, confirm, yielding = ensure_procs(procs)
      memos = Percolate.memoizer.async_method_memos(fname)
      result = memos[args]
      submitted = result && result.submitted?

      log = Percolate.log
      log.debug("Entering task #{fname}")

      if submitted # LSF job was submitted
        log.debug("#{fname} LSF job '#{command}' is already submitted")

        if result.value? # if submitted, result is not nil, see above
          log.debug("Returning memoized #{fname} result: #{result}")
        else
          begin
            if result.failed?
              raise PercolateAsyncTaskError,
                    "#{fname} args: #{args.inspect} failed"
            elsif result.finished? &&
            confirm.call(*args.take(confirm.arity.abs))
              result.finished!(yielding.call(*args.take(yielding.arity.abs)))
              log.debug("Postconditions for #{fname} satsified; " +
                        "returning #{result}")
            else
              log.debug("Postconditions for #{fname} not satsified; " +
                        "returning nil")
            end
          rescue PercolateAsyncTaskError => pate
            # Any of the having, confirm or yielding procs may throw this
            log.error("#{fname} requires attention: #{pate.message}")
            raise pate
          end
        end
      else # Can we submit the LSF job?
        if !having.call(*args.take(having.arity.abs))
          log.debug("Preconditions for #{fname} not satisfied; " +
                    "returning nil")
        else
          log.debug("Preconditions for #{fname} satisfied; " +
                    "submitting '#{command}'")

          if submit_async(fname, command)
            task_id = Percolate.task_identity(fname, args)
            submission_time = Time.now
            memos[args] = Result.new(fname, task_id, submission_time)
          end
        end
      end

      result
    end

    def async_task_array fname, args_arrays, commands, array_file, command, env,
                         procs = {}
      having, confirm, yielding = ensure_procs(procs)
      memos = Percolate.memoizer.async_method_memos(fname)

      # If first in array was submitted, all were submitted
      submitted = memos.has_key?(args_arrays.first) &&
      memos[args_arrays.first].submitted?

      log = Percolate.log
      log.debug("Entering task #{fname}")

      results = Array.new(args_arrays.size)

      if submitted
        args_arrays.each_with_index { |args, i|
          result = memos[args]
          results[i] = result
          log.debug("Checking #{fname}[#{i}] args: #{args.inspect}, " +
                    "result: #{result}")

          if result.value?
            log.debug("Returning memoized #{fname} result: #{result}")
          else
            begin
              if result.failed?
                raise PercolateAsyncTaskError,
                      "#{fname}[#{i}] args: #{args.inspect} failed"
              elsif result.finished? &&
              confirm.call(*args.take(confirm.arity.abs))
                result.finished!(yielding.call(*args.take(yielding.arity.abs)))
                log.debug("Postconditions for #{fname} satsified; " +
                          "collecting #{result}")
              else
                log.debug("Postconditions for #{fname} not satsified; " +
                          "collecting nil")
              end
            rescue PercolateAsyncTaskError => pate
              # Any of the having, confirm or yielding procs may throw this
              log.error("#{fname}[#{i}] requires attention: #{pate.message}")
              raise pate
            end
          end
        }
      else
        # Can't submit any members of a job array until all their
        # preconditions are met
        pre = args_arrays.collect { |args|
          having.call(*args.take(having.arity.abs))
        }

        if pre.include?(false)
          log.debug("Preconditions for #{fname} not satisfied; " +
                    "returning nil")
        else
          array_task_id = Percolate.task_identity(fname, args_arrays)
          log.debug("Preconditions for #{fname} are satisfied; " +
                    "submitting '#{command}' with env #{env}")
          log.debug("Writing #{commands.size} commands to #{array_file}")
          write_array_commands(array_file, fname, args_arrays, commands)

          if submit_async(fname, command)
            submission_time = Time.now
            args_arrays.each_with_index { |args, i|
              task_id = Percolate.task_identity(fname, args)
              result = Result.new(fname, task_id, submission_time)
              memos[args] = result
              log.debug("Submitted #{fname}[#{i}] args: #{args.inspect}, " +
                        "result #{result}")
            }
          end
        end
      end

      results
    end

    def write_array_commands file, fname, args_array, commands
      File.open(file, 'w') { |f|
        args_array.zip(commands).each { |args, cmd|
          task_id = Percolate.task_identity(fname, args)
          f.puts("#{task_id}\t#{fname}\t#{args.inspect}\t#{cmd}")
        }
      }
    end

    private
    def read_array_command file, lineno
      task_id = command = nil

      File.open(file, 'r') { |f|
        f.each_line { |line|
          if f.lineno == lineno
            fields = line.chomp.split("\t")
            task_id, command = fields[0], fields[3]
            break
          end
        }
      }

      if task_id.nil?
        raise PercolateError, "No such command line #{lineno} in #{file}"
      elsif task_id.empty?
        raise PercolateError, "Empty task_id at line #{lineno} in #{file}"
      elsif command.empty?
        raise PercolateError, "Empty command at line #{lineno} in #{file}"
      else
        [task_id, command]
      end
    end

    def count_lines file
      count = 0
      open(file).each { |line| count = count + 1 }
      count
    end

    def submit_async fname, command
      # Check that the message queue has been set
      unless Asynchronous.message_queue
        raise PercolateError, "No message queue has been provided"
      end

      # Jump through hoops because bsub insists on polluting our stdout
      # TODO: pass environment variables from env
      status, stdout = system_command(command)
      success = command_success?(status)

      Percolate.log.info("submission reported #{stdout} for #{fname}")

      case
        when status.signaled?
          raise PercolateAsyncTaskError,
                "Uncaught signal #{status.termsig} from '#{command}'"
        when !success
          raise PercolateAsyncTaskError,
                "Non-zero exit #{status.exitstatus} from '#{command}'"
        else
          Percolate.log.debug("#{fname} async job '#{command}' is submitted, " +
                              "meanwhile returning nil")
      end

      success
    end
  end
end

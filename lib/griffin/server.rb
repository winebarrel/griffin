# frozen_string_literal: true

require 'grpc_kit'

require 'griffin/thread_pool'

module Griffin
  class Server
    DEFAULT_WORKER_SIZE = 10
    DEFAULT_BACKLOG_SIZE = 1024

    GRACEFUL_SHUTDOWN = '0'
    FORCIBLE_SHUTDOWN = '1'

    def initialize(worker_size: DEFAULT_WORKER_SIZE, **opts)
      @worker_size = worker_size
      @server = GrpcKit::Server.new
      @opts = opts
      @command, @signal = IO.pipe
      @socks = []
      @socks << @command
      @status = :run
    end

    def handle(handler)
      @server.handle(handler)
      handler.class.rpc_descs.each do |path, _|
        Griffin.logger.debug("Handle #{path}")
      end
    end

    def run(sock, blocking: true)
      @socks << sock

      @thread_pool = Griffin::ThreadPool.new(@worker_size) do |conn|
        @server.run(conn)
      end

      if blocking
        handle_server
      else
        Thread.new { handle_server }
      end
    end

    def shutdown(reason = GRACEFUL_SHUTDOWN)
      @signal.write(reason)
    end

    private

    def handle_server
      while @status == :run
        io = IO.select(@socks, [], [])

        io[0].each do |sock|
          if sock == @command
            break if handle_command
          end

          begin
            bench do
              conn = sock.accept_nonblock
              @thread_pool.schedule(conn[0])
            end
          rescue IO::WaitReadable, Errno::EINTR
            # nothing
          end
        end
      end

      @thread_pool.shutdown
      # unless @sever.session_count == 0
      # end
    end

    def handle_command
      case @command.read(1)
      when FORCIBLE_SHUTDOWN
        Griffin.logger.info('Shuting down sever forcibly...')

        @status = :halt
        @server.graceful_shutdown
        true
      when GRACEFUL_SHUTDOWN
        Griffin.logger.info('Shuting down sever gracefully...')
        @status = :stop
        true
      end
    end

    def bench
      require 'benchmark'
      result = Benchmark.realtime do
        yield
      end
      puts result
    end
  end
end

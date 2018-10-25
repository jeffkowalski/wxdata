require 'thor'
require 'fileutils'
require 'logger'
require 'socket'
require 'influxdb'
include Socket::Constants

LOGFILE = File.join(Dir.home, '.log', 'ws1001.log')

UDPPORT = 6000 # udp port	# broadcast message port
BCMSG   = ['PC2000', 'SEARCH', '', 0, 0].pack 'Z8 Z8 Z16 I I'
TCPPORT = 6500	# tcp port	# console connection
SNDMSG  = ['PC2000', 'READ',   'NOWRECORD', 0, 0].pack 'Z8 Z8 Z16 I I'
FIELDS  = [
                                                      #  ord size
  {:name => "HP_HEAD"             , :pack =>  'Z8'},  #    0    8
  {:name => "HP_CMD"              , :pack =>  'Z8'},  #    1    8
  {:name => "HP_TABLE"            , :pack => 'Z16'},  #    2   16
  {:name => "HP_LEN"              , :pack =>   'I'},  #    3    4   probably HP_LEN
  {:name => "HP_CRC"              , :pack =>   'I'},  #    4    4   could be part of len
  {:name => "wind_direction"      , :pack =>   'S'},  #    5    2
  {:name => "humidity_indoor"     , :pack =>   'C'},  #    6    1
  {:name => "humidity_outdoor"    , :pack =>   'C'},  #    7    1
  {:name => "temperature_indoor"  , :pack =>   'f'},  #    8    4
  {:name => "pressure_absolute"   , :pack =>   'f'},  #    9    4
  {:name => "pressure_relative"   , :pack =>   'f'},  #   10    4
  {:name => "temperature outdoor" , :pack =>   'f'},  #   11    4
  {:name => "dewpoint"            , :pack =>   'f'},  #   12    4
  {:name => "windchill"           , :pack =>   'f'},  #   13    4
  {:name => "wind_average"        , :pack =>   'f'},  #   14    4
  {:name => "wind_gust"           , :pack =>   'f'},  #   15    4
  {:name => "rain_hourly"         , :pack =>   'f'},  #   16    4
  {:name => "rain_daily"          , :pack =>   'f'},  #   17    4
  {:name => "rain_weekly"         , :pack =>   'f'},  #   28    4
  {:name => "rain_monthly"        , :pack =>   'f'},  #   29    4
  {:name => "rain_yearly"         , :pack =>   'f'},  #   20    4
  {:name => "solar_radiation"     , :pack =>   'f'},  #   21    4
  {:name => "uv_index"            , :pack =>   'C'},  #   22    1
  {:name => "field25"             , :pack =>   'C'},  #   23    1    heat index or soil? typically 255
  {:name => "field26"             , :pack =>   'S'},  #   24    2    heat index or soil? typically 0
                                                      # total 104
]


class WS1001 < Thor
  no_commands {
    def redirect_output
      unless LOGFILE == 'STDOUT'
        logfile = File.expand_path(LOGFILE)
        FileUtils.mkdir_p(File.dirname(logfile), :mode => 0755)
        FileUtils.touch logfile
        File.chmod 0644, logfile
        $stdout.reopen logfile, 'a'
      end
      $stderr.reopen $stdout
      $stdout.sync = $stderr.sync = true
    end

    def setup_logger
      redirect_output if options[:log]

      $logger = Logger.new STDOUT
      $logger.level = options[:verbose] ? Logger::DEBUG : Logger::INFO
      $logger.info 'starting'
    end
  }

  class_option :log,     :type => :boolean, :default => true, :desc => "log output to ~/.ws1001.log"
  class_option :verbose, :type => :boolean, :aliases => "-v", :desc => "increase verbosity"

  desc "record-status", "record the current usage data to database"
  option :station, :type => :string, :default => '<broadcast>', :desc => 'ip addr of weather station'

  def record_status
    setup_logger

    $logger.info 'opening udp socket'
    udpsock = UDPSocket.new
    begin
      udpsock.setsockopt Socket::SOL_SOCKET, Socket::SO_BROADCAST, true
      $logger.info "sending broadcast to #{options[:station]} on port #{UDPPORT}"
      udpsock.send BCMSG, 0, options[:station], UDPPORT
    rescue => e
      $logger.error "caught exception #{e}"
      $logger.error e.backtrace.join("\n")
    else
      begin
        addr = (Socket.ip_address_list.detect{|intf| intf.ipv4_private?}).ip_address
        sockaddr = Socket.sockaddr_in TCPPORT, addr
        $logger.info "opening server on port #{addr}:#{TCPPORT}"
        server = Socket.new AF_INET, SOCK_STREAM, 0
        timeval = [90, 0].pack "l_2" # 90 seconds
        server.setsockopt Socket::SOL_SOCKET, Socket::SO_RCVTIMEO, timeval
        server.setsockopt Socket::SOL_SOCKET, Socket::SO_SNDTIMEO, timeval
        server.bind sockaddr
        server.listen 5
        tries = 0
        begin
          $logger.info "waiting for connection on port #{TCPPORT}"
          client_socket, client_sockaddr = server.accept_nonblock
        rescue Errno::EAGAIN, Errno::ECONNABORTED, Errno::EINTR, Errno::EWOULDBLOCK => e
          $logger.info "handling benign exception: #{e}"
          IO.select([server], nil, nil, 10) # 10 second timeout
          if (tries += 1) > 6
            $logger.info "too many tries #{tries}, exiting"
            exit
          end
          $logger.info "retrying #{tries}"
          retry
        else
          $logger.info "accepted connection from #{client_sockaddr.ip_unpack.join(':')}"
          sleep 2
          $logger.info 'sending request'
          client_socket.write SNDMSG
          $logger.info 'awaiting response'
          rcvmsg = client_socket.read
          timestamp = Time.now.to_i

          File.open("/tmp/nowrecord", "w") { |file| file.write(rcvmsg) }

          # Unpack NOWRECORD message received from console
          packing = (FIELDS.collect { |field| field[:pack] }).join ''
          $logger.info "unpacking #{packing}" # c.f. "A8 A8 Z16 S C I C S C2 f14 C2"
          msgcontent = rcvmsg.unpack packing

          (0..FIELDS.length-1).each { |index|
            $logger.info FIELDS[index][:name].ljust(21) + msgcontent[index].class.to_s.ljust(10) + msgcontent[index].to_s
          }

          influxdb = InfluxDB::Client.new 'wxdata'
          (0..FIELDS.length-1).each { |index|
            data = { values: { value:  msgcontent[index] }, timestamp: timestamp }
            influxdb.write_point FIELDS[index][:name], data unless msgcontent[index].nil?
          }
        ensure
          $logger.info "closing client connection"
          client_socket.close unless client_socket.nil?
        end
      rescue => e
        $logger.error "caught exception #{e}"
        $logger.error e.backtrace.join("\n")
        exit
      ensure
        $logger.info "closing server"
        server.close unless server.nil?
      end
    ensure
      $logger.info "closing udp socket"
      udpsock.close unless udpsock.nil?

      $logger.info "done"
    end
  end
end

WS1001.start

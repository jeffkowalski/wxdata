#!/usr/bin/env ruby

require 'thor'
require 'fileutils'
require 'logger'
require 'socket'
require 'influxdb'

LOGFILE = File.join(Dir.home, '.log', 'ws1001.log')

UDPPORT = 6000 # udp port  # broadcast message port
BCMSG   = ['PC2000', 'SEARCH', '', 0, 0].pack 'Z8 Z8 Z16 I I'
TCPPORT = 6500 # tcp port  # console connection
SNDMSG  = ['PC2000', 'READ', 'NOWRECORD', 0, 0].pack 'Z8 Z8 Z16 I I'
FIELDS  = [
  #  ord size
  { pack: 'Z8',  name: 'HP_HEAD' },             #    0    8
  { pack: 'Z8',  name: 'HP_CMD' },              #    1    8
  { pack: 'Z16', name: 'HP_TABLE' },            #    2   16
  { pack: 'I',   name: 'HP_LEN' },              #    3    4    maybe?
  { pack: 'I',   name: 'HP_CRC' },              #    4    4    maybe?
  { pack: 'S',   name: 'wind_direction' },      #    5    2
  { pack: 'C',   name: 'humidity_indoor' },     #    6    1
  { pack: 'C',   name: 'humidity_outdoor' },    #    7    1
  { pack: 'f',   name: 'temperature_indoor' },  #    8    4
  { pack: 'f',   name: 'pressure_absolute' },   #    9    4
  { pack: 'f',   name: 'pressure_relative' },   #   10    4
  { pack: 'f',   name: 'temperature outdoor' }, #   11    4
  { pack: 'f',   name: 'dewpoint' },            #   12    4
  { pack: 'f',   name: 'windchill' },           #   13    4
  { pack: 'f',   name: 'wind_average' },        #   14    4
  { pack: 'f',   name: 'wind_gust' },           #   15    4
  { pack: 'f',   name: 'rain_hourly' },         #   16    4
  { pack: 'f',   name: 'rain_daily' },          #   17    4
  { pack: 'f',   name: 'rain_weekly' },         #   28    4
  { pack: 'f',   name: 'rain_monthly' },        #   29    4
  { pack: 'f',   name: 'rain_yearly' },         #   20    4
  { pack: 'f',   name: 'solar_radiation' },     #   21    4
  { pack: 'C',   name: 'uv_index' },            #   22    1
  { pack: 'C',   name: 'field25' },             #   23    1    heat index or soil? typically 255
  { pack: 'S',   name: 'field26' },             #   24    2    heat index or soil? typically 0
  # total 104
].freeze

class WS1001 < Thor
  no_commands do
    def redirect_output
      unless LOGFILE == 'STDOUT'
        logfile = File.expand_path(LOGFILE)
        FileUtils.mkdir_p(File.dirname(logfile), mode: 0o755)
        FileUtils.touch logfile
        File.chmod 0o644, logfile
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
  end

  class_option :log,     type: :boolean, default: true, desc: 'log output to ~/.ws1001.log'
  class_option :verbose, type: :boolean, aliases: '-v', desc: 'increase verbosity'

  desc 'record-status', 'record the current usage data to database'
  option :station, type: :string, default: '<broadcast>', desc: 'ip addr of weather station'

  def record_status
    setup_logger

    $logger.info 'opening udp socket'
    udpsock = UDPSocket.new
    begin
      udpsock.setsockopt Socket::SOL_SOCKET, Socket::SO_BROADCAST, true
      $logger.info "sending broadcast to #{options[:station]} on port #{UDPPORT}"
      udpsock.send BCMSG, 0, options[:station], UDPPORT
    rescue StandardError => e
      $logger.error "caught exception #{e}"
      $logger.error e.backtrace.join("\n")
    else
      begin
        addr = Socket.ip_address_list.detect(&:ipv4_private?).ip_address
        sockaddr = Socket.sockaddr_in TCPPORT, addr
        $logger.info "opening server on port #{addr}:#{TCPPORT}"
        server = Socket.new Socket::AF_INET, Socket::SOCK_STREAM, 0
        timeval = [90, 0].pack 'l_2' # 90 seconds
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

          File.open('/tmp/nowrecord', 'w') { |file| file.write(rcvmsg) }

          # Unpack NOWRECORD message received from console
          packing = (FIELDS.collect { |field| field[:pack] }).join ''
          $logger.info "unpacking #{packing}"
          msgcontent = rcvmsg.unpack packing

          (0..FIELDS.length - 1).each do |index|
            $logger.info FIELDS[index][:name].ljust(21) +
                         msgcontent[index].class.to_s.ljust(10) +
                         msgcontent[index].to_s
          end

          influxdb = InfluxDB::Client.new 'wxdata'
          (0..FIELDS.length - 1).each do |index|
            data = { values: { value: msgcontent[index] }, timestamp: timestamp }
            influxdb.write_point FIELDS[index][:name], data unless msgcontent[index].nil?
          end
        ensure
          $logger.info 'closing client connection'
          client_socket.close unless client_socket.nil?
        end
      rescue StandardError => e
        $logger.error "caught exception #{e}"
        $logger.error e.backtrace.join("\n")
        exit
      ensure
        $logger.info 'closing server'
        server.close unless server.nil?
      end
    ensure
      $logger.info 'closing udp socket'
      udpsock.close unless udpsock.nil?

      $logger.info 'done'
    end
  end
end

WS1001.start

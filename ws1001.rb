#!/usr/bin/env ruby
# frozen_string_literal:true

require 'rubygems'
require 'bundler/setup'
Bundler.require(:default)

UDPPORT = 6000 # udp port  # broadcast message port
BCMSG   = ['PC2000', 'SEARCH', '', 0, 0].pack 'Z8 Z8 Z16 I I'
TCPPORT = 6500 # tcp port  # console connection
SNDMSG  = ['PC2000', 'READ', 'NOWRECORD', 0, 0].pack 'Z8 Z8 Z16 I I'
# rubocop: disable Layout/ExtraSpacing, Layout/SpaceInsideParens, Style/NumericLiterals
FIELDS  = [
  #                                                                                                  ord size
  { pack: 'Z8',  name: 'HP_HEAD' },                                                              #    0    8
  { pack: 'Z8',  name: 'HP_CMD' },                                                               #    1    8
  { pack: 'Z16', name: 'HP_TABLE' },                                                             #    2   16
  { pack: 'I',   name: 'HP_LEN' },                                                               #    3    4    maybe?
  { pack: 'I',   name: 'HP_CRC' },                                                               #    4    4    maybe?
  { pack: 'S',   name: 'wind_direction',      validator: ->(v) { v.between?(  0,   360) } },     #    5    2
  { pack: 'C',   name: 'humidity_indoor',     validator: ->(v) { v.between?(  0,   100) } },     #    6    1
  { pack: 'C',   name: 'humidity_outdoor',    validator: ->(v) { v.between?(  0,   100) } },     #    7    1
  { pack: 'f',   name: 'temperature_indoor',  validator: ->(v) { v.between?(-99,  1000) } },     #    8    4
  { pack: 'f',   name: 'pressure_absolute',   validator: ->(v) { v.between?( 10,    40) } },     #    9    4
  { pack: 'f',   name: 'pressure_relative',   validator: ->(v) { v.between?( 10,    40) } },     #   10    4
  { pack: 'f',   name: 'temperature_outdoor', validator: ->(v) { v.between?(-99,  1000) } },     #   11    4
  { pack: 'f',   name: 'dewpoint',            validator: ->(v) { v.between?(-99,  1000) } },     #   12    4
  { pack: 'f',   name: 'windchill',           validator: ->(v) { v.between?(-99,  1000) } },     #   13    4
  { pack: 'f',   name: 'wind_average',        validator: ->(v) { v.between?(  0,  1000) } },     #   14    4
  { pack: 'f',   name: 'wind_gust',           validator: ->(v) { v.between?(  0,  1000) } },     #   15    4
  { pack: 'f',   name: 'rain_hourly',         validator: ->(v) { v.between?(  0,  1000) } },     #   16    4
  { pack: 'f',   name: 'rain_daily',          validator: ->(v) { v.between?(  0,  1000) } },     #   17    4
  { pack: 'f',   name: 'rain_weekly',         validator: ->(v) { v.between?(  0,  1000) } },     #   28    4
  { pack: 'f',   name: 'rain_monthly',        validator: ->(v) { v.between?(  0,  1000) } },     #   29    4
  { pack: 'f',   name: 'rain_yearly',         validator: ->(v) { v.between?(  0,  1000) } },     #   20    4
  { pack: 'f',   name: 'solar_radiation',     validator: ->(v) { v.between?(  0, 10000) } },     #   21    4
  { pack: 'C',   name: 'uv_index',            validator: ->(v) { v.between?(  0,   100) } },     #   22    1
  { pack: 'C',   name: 'field25' },                                                              #   23    1    heat index or soil? typically 255
  { pack: 'S',   name: 'field26' }                                                               #   24    2    heat index or soil? typically 0
  # total 104
].freeze
# rubocop: enable Layout/ExtraSpacing, Layout/SpaceInsideParens, Style/NumericLiterals

class WS1001 < RecorderBotBase
  no_commands do
    def query_panel(verb)
      @logger.info 'opening udp socket'
      udpsock = UDPSocket.new
      udpsock.setsockopt Socket::SOL_SOCKET, Socket::SO_BROADCAST, true

      with_rescue([Errno::EAGAIN,
                   Errno::ECONNABORTED,
                   Errno::EINTR,
                   Errno::EWOULDBLOCK], @logger) do |_try|
        @logger.info "sending broadcast to #{options[:station]} on port #{UDPPORT}"
        udpsock.send BCMSG, 0, options[:station], UDPPORT

        begin
          addr = Socket.ip_address_list.detect(&:ipv4_private?).ip_address
          sockaddr = Socket.sockaddr_in TCPPORT, addr
          @logger.info "opening server on port #{addr}:#{TCPPORT}"
          server = Socket.new Socket::AF_INET, Socket::SOCK_STREAM, 0
          timeval = [90, 0].pack 'l_2' # 90 seconds
          server.setsockopt Socket::SOL_SOCKET, Socket::SO_RCVTIMEO, timeval
          server.setsockopt Socket::SOL_SOCKET, Socket::SO_SNDTIMEO, timeval
          server.bind sockaddr
          server.listen 5

          @logger.info "waiting for connection on port #{TCPPORT}"
          with_rescue([Errno::EAGAIN,
                       Errno::ECONNABORTED,
                       Errno::EINTR,
                       Errno::EWOULDBLOCK], @logger) do |_try2|
            IO.select([server], nil, nil, 10) # 10 second timeout
            client_socket, client_sockaddr = server.accept_nonblock
            @logger.info "accepted connection from #{client_sockaddr.ip_unpack.join(':')}"
            sleep 2
            @logger.info 'sending request'
            client_socket.write verb
            @logger.info 'awaiting response'
            client_socket.read # return
          ensure
            @logger.info 'closing client connection'
            client_socket&.close
          end
        ensure
          @logger.info 'closing server'
          server&.close
        end
      end
    ensure
      @logger.info 'closing udp socket'
      udpsock&.close
    end
  end

  method_option :station, type: :string, default: '<broadcast>', desc: 'ip addr of weather station', for: :record_status
  no_commands do
    def main
      rcvmsg = query_panel(SNDMSG)
      timestamp = Time.now.to_i
      # File.open('/tmp/nowrecord', 'w') { |file| file.write(rcvmsg) }

      # Unpack NOWRECORD message received from console
      packing = (FIELDS.collect { |field| field[:pack] }).join ''
      @logger.info "unpacking #{packing}"
      msgcontent = rcvmsg.unpack packing

      influxdb = InfluxDB::Client.new 'wxdata' unless options[:dry_run]
      data = []
      (0..FIELDS.length - 1).each do |index|
        value = msgcontent[index]
        @logger.info FIELDS[index][:name].ljust(21) +
                     value.class.to_s.ljust(10) +
                     value.to_s
        if !value.nil? && (!FIELDS[index].key?(:validator) || FIELDS[index][:validator].call(value))
          datum = { series: FIELDS[index][:name],
                    values: { value: value },
                    timestamp: timestamp }
          # @logger.debug datum
          data.push datum
        else
          @logger.warn "#{FIELDS[index][:name]} #{value} is out of valid range"
        end
        influxdb.write_points data unless options[:dry_run]
      end
    end
  end
end

WS1001.start

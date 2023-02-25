#!/usr/bin/env ruby
# frozen_string_literal:true

require 'rubygems'
require 'bundler/setup'
Bundler.require(:default)

UDPPORT = 46_000 # udp port  # broadcast message port

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

CMD_HEADER = [0xFF, 0xFF].freeze
class Preamble1 < BinData::Record
  endian :big

  uint16 :header
  uint8  :command
  uint8  :packet_size
end

class Preamble2 < BinData::Record
  endian :big

  uint16 :header
  uint8  :command
  uint16 :packet_size
end

CMD_DISCOVER = [0x12, 0x00].freeze
class DiscoveryRecord < Preamble2
  array  :mac_addr, type: :uint8, initial_length: 6
  array  :ip_addr,  type: :uint8, initial_length: 4
  uint16 :port
  uint8  :ssid_len
  string :ssid, read_length: :ssid_len
  uint8  :checksum
end

CMD_READ_WUNDERGROUND = [0x20].freeze
class WundergroundRecord < Preamble1
  uint8  :id_size
  string :id, read_length: :id_size
  uint8  :password_size
  string :password, read_length: :password_size
  uint8  :fix
  #uint8  :checksum
end

CMD_READ_WOW = [0x22].freeze
class WOWRecord < Preamble1
  uint8  :id_size
  string :id, read_length: :id_size
  uint8  :password_size
  string :password, read_length: :password_size
  uint8  :station_num_size
  string :station_num, read_length: :station_num_size
  uint8  :fix
  uint8  :checksum
end

CMD_READ_CUSTOMIZED = [0x2A].freeze
class CustomizedRecord < Preamble1
  uint8  :id_size
  string :id, read_length: :id_size
  uint8  :password_size
  string :password, read_length: :password_size
  uint8  :server_size
  string :server, read_length: :server_size
  uint16 :port
  uint16 :interval
  uint8  :server_type
  uint8  :active
  uint8  :checksum
end

CMD_GW1000_LIVEDATA = [0x27].freeze
class GW1000LiveDataRecord < Preamble1
end

CMD_READ_RAINDATA = [0x34].freeze
class RainDataRecord < Preamble1
  uint32  :rain_rate
  uint32  :rain_day
  uint32  :rain_week
  uint32  :rain_month
  uint32  :rain_year
  uint8   :checksum
end

CMD_READ_USRPATH = [0x51].freeze
class UsrPathRecord < Preamble1
  uint8  :ecowitt_path_size
  string :ecowitt_path, read_length: :ecowitt_path_size
  uint8  :wu_path_size
  string :wu_path, read_length: :wu_path_size
  uint8  :checksum
end

CMD_READ_RAIN = [0x57].freeze
class RainRecord < Preamble1
  uint16  :rain_rate
  uint32  :rain_day
  uint32  :rain_week
  uint32  :rain_month
  uint32  :rain_year
  uint16  :rain_event
  uint16  :rain_hour
  uint16  :piezo_rain_rate
  uint16  :piezo_event_rain
  uint16  :piezo_hourly_rain
  uint32  :piezo_daily_rain
  uint32  :piezo_weekly_rain
  uint32  :piezo_yearly_rain
  array   :piezo_gain10, type: :uint16, initial_length: 10
  array   :reset_rain_time, type: :uint8, initial_length: 3
  uint8   :checksum
end

class WS5000 < RecorderBotBase
  no_commands do
    def cmd_to_packet(cmd)
      # CMD_HEADER cmd size checksum   ; checksum doesn't include CMD_HEADER
      size = CMD_HEADER.length + cmd.length
      body = cmd + [size]
      checksum = body.sum & 0x00FF
      (CMD_HEADER + body + [checksum]).pack('C*')
    end

    def fetch_record(socket, command, record)
      packet = cmd_to_packet(command)
      pp packet
      socket.write(packet)

      response = socket.recv(1024)
      pp response
      result = record.read(response)
      pp result
      result
    end

    def query_panel
      @logger.info 'opening udp socket'
      udpsock = UDPSocket.new
      udpsock.setsockopt Socket::SOL_SOCKET, Socket::SO_BROADCAST, true

      with_rescue([Errno::EAGAIN,
                   Errno::ECONNABORTED,
                   Errno::EINTR,
                   Errno::EWOULDBLOCK], @logger) do |_try|
        @logger.info "sending broadcast to #{options[:station]} on port #{UDPPORT}"
        packet = cmd_to_packet(CMD_DISCOVER)
        pp packet
        udpsock.send(packet, 0, options[:station], UDPPORT)
        timeval = [5, 0].pack 'l_2' # 5 seconds
        udpsock.setsockopt Socket::SOL_SOCKET, Socket::SO_RCVTIMEO, timeval
        udpsock.setsockopt Socket::SOL_SOCKET, Socket::SO_SNDTIMEO, timeval

        begin
          rec = DiscoveryRecord.new
          response = udpsock.recv(1024)
          discovery = rec.read(response)
          pp discovery

          client_socket = TCPSocket.new discovery[:ip_addr].map(&:to_s).join('.'), discovery[:port].to_i

          # fetch_record(client_socket, CMD_READ_WUNDERGROUND, WundergroundRecord.new)
          # fetch_record(client_socket, CMD_GW1000_LIVEDATA, GW1000LiveDataRecord.new)
          fetch_record(client_socket, CMD_READ_CUSTOMIZED, CustomizedRecord.new)
          # fetch_record(client_socket, CMD_READ_RAIN, RainRecord.new)
          # fetch_record(client_socket, CMD_READ_WOW, WOWRecord.new)
          fetch_record(client_socket, CMD_READ_USRPATH, UsrPathRecord.new)
          # fetch_record(client_socket, CMD_READ_RAINDATA, RainDataRecord.new)
        ensure
          @logger.info 'closing client connection'
          client_socket&.close
        end
      ensure
        @logger.info 'closing udp socket'
        udpsock&.close
      end
    end
  end

  method_option :station, type: :string, default: '<broadcast>', desc: 'ip addr of weather station', for: :record_status
  no_commands do
    def main
      rcvmsg = query_panel
      exit

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

WS5000.start

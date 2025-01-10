#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
Bundler.require(:default)

class String
  def to_t
    DateTime.parse(self).to_time.to_i
  end
end

# rubocop: disable Layout/ExtraSpacing, Layout/CommentIndentation, Layout/HashAlignment
FIELD_TRANSFORMS  = {
#  ws5000                   type,        rename                                 example
#  -------------------    ----------------------------------------------------  ----------------------------------------
  'dateutc'            => { type: nil,   name: nil },                           # 1677369300000
  'tempinf'            => { type: :to_f, name: 'temperature_indoor' },          # 64.9
  'battin'             => { type: :to_i, name: 'battery_indoor' },              # 1
  'humidityin'         => { type: :to_i, name: 'humidity_indoor' },             # 43
  'baromrelin'         => { type: :to_f, name: 'pressure_relative' },           # 29.232
  'baromabsin'         => { type: :to_f, name: 'pressure_absolute' },           # 29.232
  'tempf'              => { type: :to_f, name: 'temperature_outdoor' },         # 46
  'battout'            => { type: :to_i, name: 'battery_outdoor' },             # 1
  'battrain'           => { type: :to_i, name: 'battery_rain' },                # 1
  'humidity'           => { type: :to_i, name: 'humidity_outdoor' },            # 77
  'winddir'            => { type: :to_i, name: 'wind_direction' },              # 255
  'winddir_avg10m'     => { type: :to_i, name: 'wind_direction_average_10m' },  # 255
  'windspeedmph'       => { type: :to_f, name: 'wind_speed' },                  # 0
  'windspdmph_avg10m'  => { type: :to_f, name: 'wind_gust_average_10m' },       # 0
  'windgustmph'        => { type: :to_f, name: 'wind_gust' },                   # 1.3
  'maxdailygust'       => { type: :to_f, name: 'wind_gust_max_daily' },         # 12.3
  'hourlyrainin'       => { type: :to_f, name: 'rain_hourly' },                 # 0
  'eventrainin'        => { type: :to_f, name: 'rain_event' },                  # 0
  'dailyrainin'        => { type: :to_f, name: 'rain_daily' },                  # 0.028
  'weeklyrainin'       => { type: :to_f, name: 'rain_weekly' },                 # 0.98
  'monthlyrainin'      => { type: :to_f, name: 'rain_monthly' },                # 2.244
  'yearlyrainin'       => { type: :to_f, name: 'rain_yearly' },                 # 2.366
  'solarradiation'     => { type: :to_f, name: 'solar_radiation' },             # 142.3
  'uv'                 => { type: :to_i, name: 'uv_index' },                    # 1
  'batt_co2'           => { type: :to_i, name: 'battery_co2' },                 # 1
  # calculated on server:
  'feelsLike'          => { type: :to_f, name: 'feels_like_outdoor' },          # 46
  'dewPoint'           => { type: :to_f, name: 'dew_point_outdoor' },           # 39.2
  'feelsLikein'        => { type: :to_f, name: 'feels_like_indoor' },           # 64.9
  'dewPointin'         => { type: :to_f, name: 'dew_point_indoor' },            # 41.9
  'lastRain'           => { type: :to_t, name: 'last_rain' },                   # "2023-02-25T14:14:00.000Z"
  'date'               => { type: nil,   name: nil },                           # "2023-02-25T23:55:00.000Z"
  # strange recent additions
  'pm25_in'            => { type: nil,   name: nil },
  'pm25_in_24h'        => { type: nil,   name: nil },
  'aqi_pm25'           => { type: nil,   name: nil },
  'aqi_pm25_24h'       => { type: nil,   name: nil },
  'aqi_pm25_in'        => { type: nil,   name: nil },
  'aqi_pm25_in_24h'    => { type: nil,   name: nil },
  'batt_25in'          => { type: nil,   name: nil }
}.freeze
# rubocop: enable Layout/ExtraSpacing, Layout/CommentIndentation, Layout/HashAlignment

class AmbientWeather < RecorderBotBase
  no_commands do
    method_option :num_records, type: :numeric, default: 12, desc: 'number of records to request', for: :record_status
    def main
      credentials = load_credentials

      begin
        response = with_rescue([RestClient::Exceptions::OpenTimeout, RestClient::Exceptions::ReadTimeout, RestClient::TooManyRequests, RestClient::Unauthorized], logger) do |_try|
          RestClient.get "https://rt.ambientweather.net/v1/devices/#{credentials[:macAddress]}?applicationKey=#{credentials[:applicationKey]}&apiKey=#{credentials[:apiKey]}&limit=#{options[:num_records]}"
        end
      rescue RestClient::TooManyRequests
        @logger.warn 'too many "TooManyRequests", try again later'
        return
      end

      @logger.debug response
      response = JSON.parse(response)

      response.each do |record|
        timestamp = record['date'].to_t
        @logger.info "record #{record['date']}"

        data = []
        record.each_pair do |key, value|
          unless FIELD_TRANSFORMS.key?(key)
            @logger.error "unrecognized field '#{key}'"
            next
          end

          transform = FIELD_TRANSFORMS[key]
          @logger.debug key.ljust(19) + transform[:name].to_s.ljust(27) + value.to_s

          next if value.nil? || transform[:name].nil?

          datum = { series: transform[:name],
                    values: { value: value.send(transform[:type]) },
                    timestamp: timestamp }
          data.push datum
        end

        influxdb = InfluxDB::Client.new 'wxdata' unless options[:dry_run]
        influxdb.write_points data unless options[:dry_run]
      end
    end
  end
end

AmbientWeather.start

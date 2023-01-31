#!/usr/bin/env ruby
# frozen_string_literal:true

require 'rubygems'
require 'bundler/setup'
Bundler.require(:default)

# rubocop: disable Layout/ExtraSpacing, Layout/CommentIndentation, Layout/HashAlignment
FIELD_RENAMES  = {
#  ws5000                 rename                         description
#  -------------------    ------------------------------ ----------------------------------------
# 'PASSKEY'            => nil,
  'baromabsin'         => 'pressure_absolute',
  'baromrelin'         => 'pressure_relative',
  'batt_co2'           => 'battery_co2',
  'batterywarning'     => 'warning_battery',             # warn if battery level of all known sensors is critical (pre-defined)
  'battin'             => 'battery_indoor',
  'battout'            => 'battery_outdoor',
  'battrain'           => 'battery_rain',
# 'brightness'         => nil,
  'co2warning'         => 'warning_co2',                 # reports an alarm when a WH45 reports a value above CO2_WARNLEVEL
  'dailyrainin'        => 'rain_daily',
# 'dateutc'            => nil,
  'dewptf'             => 'dewpoint',
  'eventrainin'        => 'rain_event',
  'feelslikef'         => 'feels_like',
  'heatindexf'         => 'heat_index',
  'hourlyrainin'       => 'rain_hourly',
  'humidity'           => 'humidity_outdoor',
  'humidityin'         => 'humidity_indoor',
  'intvlwarning'       => 'warning_interval',             # interval warning
  'isintvl'            => 'interval',
# 'isintvl10'          => nil,
  'leakwarning'        => 'warning_leak',                 # warn if any WH55 reports a leak
  'maxdailygust'       => 'wind_gust_max_daily',
  'monthlyrainin'      => 'rain_monthly',
  'running'            => 'running',                      # weather station connected
  'sensorwarning'      => 'warning_sensor',               # warn if data for mandatory sensor (configurable list of fields e.g. wh65batt) is missed
  'solarradiation'     => 'solar_radiation',
# 'stationtype'        => nil,
  'stormwarning'       => 'warning_storm',                # warn if air pressure rises/drops more than 1.75 hPa/hour or 3.75hPa/3hr with expiry time of 60 minutes (all values configurable)
  'sunhours'           => 'sun_hours',
  'tempf'              => 'temperature_outdoor',
  'tempinf'            => 'temperature_indoor',
# 'time'               => nil,
  'tswarning'          => 'warning_thunderstorm',         # warn if lightning sensor WH57/DP60 present, count of lightnings is more than TSTORM_WARNCOUNT and distance is less or equal TSTORM_WARNDIST with expiry time of TSTORM_EXPIRE minutes (all values configurable)
  'updatewarning'      => 'warning_update',               # warn if there's a new firmware for the weather station available
  'uv'                 => 'uv_index',
  'weeklyrainin'       => 'rain_weekly',
  'windchillf'         => 'windchill',
  'winddir'            => 'wind_direction',
  'winddir_avg10m'     => 'wind_direction_average_10m',
  'windgustmph'        => 'wind_gust',
  'windgustmph_max10m' => 'wind_gust_max_10m',
  'windspdmph_avg10m'  => 'wind_gust_average_10m',
  'windspeedmph'       => 'wind_speed',
  'wswarning'          => 'warning_watchdog',             # warn if weather station did not report within 3 send-intervals (configurable)
  'yearlyrainin'       => 'rain_yearly',
}.freeze
# rubocop: enable Layout/ExtraSpacing, Layout/CommentIndentation, Layout/HashAlignment

class WS5000 < RecorderBotBase
  no_commands do
    def main
      response = RestClient.get 'http://192.168.7.207:8080/JSON/units=e?status'
      response = JSON.parse response

      timestamp = DateTime.parse(response['dateutc']).to_time.to_i

      influxdb = InfluxDB::Client.new 'wxdata' unless options[:dry_run]
      data = []
      response.each_key do |index|
        value = response[index]
        rename = FIELD_RENAMES[index]
        @logger.info index.ljust(19) +
                     rename.to_s.ljust(27) +
                     value.to_s
        if !value.nil? && !rename.nil?
          datum = { series: rename,
                    values: { value: value },
                    timestamp: timestamp }
          # @logger.debug datum
          data.push datum
        end
        influxdb.write_points data unless options[:dry_run]
      end
    end
  end
end

WS5000.start

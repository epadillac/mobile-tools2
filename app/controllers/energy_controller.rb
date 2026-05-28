require "net/http"
require "json"

class EnergyController < ApplicationController
  ENERGY_API_URL = "https://83ae-189-154-24-189.ngrok-free.app/energy/canadian_solar".freeze

  layout "split_checks"

  def index
    @today_kwh = fetch_today_kwh
    @fetched_at = Time.current
  rescue StandardError => e
    Rails.logger.error("Energy fetch failed: #{e.message}")
    @today_kwh = nil
    @fetched_at = Time.current
    @fetch_error = e.message
  end

  private

  def fetch_today_kwh
    uri = URI(ENERGY_API_URL)
    # verify_mode is VERIFY_NONE because this is a temporary ngrok dev URL and
    # macOS Ruby's OpenSSL trips on "unable to get certificate CRL" against it.
    # Re-enable verification once the upstream moves to a stable HTTPS endpoint.
    response = Net::HTTP.start(
      uri.host,
      uri.port,
      use_ssl: uri.scheme == "https",
      verify_mode: OpenSSL::SSL::VERIFY_NONE,
      open_timeout: 5,
      read_timeout: 10
    ) do |http|
      http.get(uri.request_uri, "ngrok-skip-browser-warning" => "true")
    end

    return nil unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)["today"]
  end
end
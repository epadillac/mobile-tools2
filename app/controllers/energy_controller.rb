require "net/http"
require "json"

class EnergyController < ApplicationController
  ENERGY_API_URL = ENV.fetch(
    "ENERGY_API_URL",
    "https://energy-viewer2.fly.dev/energy/all"
  ).freeze

  # Inverters in display order: Canadian Solar first, then GoodWe, then Aurora.
  SOURCES = [
    { key: "canadian_solar", name: "Canadian Solar" },
    { key: "goodwe", name: "GoodWe" },
    { key: "aurora", name: "Aurora" }
  ].freeze

  layout "split_checks"

  def index
    @energy = fetch_energy
    @sources = SOURCES
    @fetched_at = Time.current
  rescue StandardError => e
    Rails.logger.error("Energy fetch failed: #{e.message}")
    @energy = nil
    @sources = SOURCES
    @fetched_at = Time.current
    @fetch_error = e.message
  end

  private

  def fetch_energy
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

    JSON.parse(response.body)
  end
end
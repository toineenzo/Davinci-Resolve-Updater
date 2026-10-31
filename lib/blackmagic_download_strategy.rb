# frozen_string_literal: true

# Homebrew download strategy for DaVinci Resolve.
#
# Blackmagic has no stable download links: POSTing the registration form to
# /api/register/us/download/<downloadId> returns a signed, short-lived URL.
# The cask's url is that (stable) endpoint, so Homebrew's cache key stays
# stable; this strategy swaps in the signed URL at download time.
#
# Registration data is read from the same key=value .config that
# update-resolve.sh writes: HOMEBREW_RESOLVE_CONFIG if set, otherwise the
# .config at the root of this tap.

require "download_strategy"
require "json"
require "net/http"
require "uri"

class BlackmagicDownloadStrategy < CurlDownloadStrategy
  FIELDS = %w[firstname lastname email phone country state city street].freeze
  REFER_ID = "77ef91f67a9e411bbbe299e595b4cfcc"
  USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " \
               "(KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36"

  private

  def resolve_url_basename_time_file_size(url, timeout: nil)
    super(signed_url, timeout:)
  end

  def signed_url
    @signed_url ||= begin
      uri = URI(url)
      req = Net::HTTP::Post.new(uri)
      req["Content-Type"] = "application/json;charset=UTF-8"
      req["Accept"] = "application/json, text/plain, */*"
      req["Origin"] = "https://www.blackmagicdesign.com"
      req["Referer"] = "https://www.blackmagicdesign.com/support/download/#{REFER_ID}/Mac%20OS%20X"
      req["User-Agent"] = USER_AGENT
      req.body = registration.merge("product" => "DaVinci Resolve").to_json

      res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }
      body = res.body.to_s.strip
      unless res.is_a?(Net::HTTPSuccess) && body.start_with?("http")
        raise CurlDownloadStrategyError.new(url, "Blackmagic download API refused the request: #{body}")
      end

      body
    end
  end

  def registration
    path = ENV.fetch("HOMEBREW_RESOLVE_CONFIG", File.expand_path("../.config", __dir__))
    setup = "Run once to save it: \"$(brew --repo toineenzo/resolve)/update-resolve.sh\" --reconfigure --check-only"
    raise CurlDownloadStrategyError.new(url, "No registration info at #{path}. #{setup}") unless File.exist?(path)

    # Plain key=value parsing, same as update-resolve.sh (no shell evaluation)
    config = File.readlines(path, chomp: true).filter_map do |line|
      key, value = line.split("=", 2)
      [key, value] if value && FIELDS.include?(key)
    end.to_h

    missing = FIELDS.reject { |f| config[f].to_s.strip != "" }
    raise CurlDownloadStrategyError.new(url, "#{path} is missing #{missing.join(", ")}. #{setup}") if missing.any?

    config
  end
end

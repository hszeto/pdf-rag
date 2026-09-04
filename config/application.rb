require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module PdfRag
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Render fronts every service with Cloudflare, so the address Rails would
    # otherwise call the client is a Cloudflare edge — making every visitor look
    # like the same one. Production logs showed it plainly:
    #
    #   Started GET "/" for 172.68.174.106        <- a Cloudflare address
    #   remote_addr: 184.23.124.45, 172.68.174.106, 10.28.65.0
    #
    # Trusting those ranges makes request.remote_ip the actual visitor, which
    # corrects the request logs as well as anything that counts per visitor.
    #
    # An enumerable REPLACES Rails' own list rather than extending it, so the
    # private ranges it normally trusts — Render's internal hop, the 10.x above —
    # are carried over explicitly.
    #
    # Source: cloudflare.com/ips-v4 and /ips-v6, taken 2026-09-04. The list has an
    # upstream owner and can drift. If Cloudflare adds a range this misses,
    # remote_ip quietly reverts to the edge address; it does not become spoofable.
    CLOUDFLARE_RANGES = %w[
      173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22
      141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20
      197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13
      104.24.0.0/14 172.64.0.0/13 131.0.72.0/22
      2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32
      2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32
    ].map { |range| IPAddr.new(range) }.freeze

    config.action_dispatch.trusted_proxies =
      ActionDispatch::RemoteIp::TRUSTED_PROXIES + CLOUDFLARE_RANGES

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # The document analysis call runs off the request; see D6 in the feature spec.
    config.active_job.queue_adapter = :sidekiq

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end

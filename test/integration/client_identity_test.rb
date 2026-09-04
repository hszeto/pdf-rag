require "test_helper"

# Render fronts every service with Cloudflare, so without configuration Rails
# calls the Cloudflare edge the client and every visitor shares one identity.
# These drive ActionDispatch::RemoteIp with the application's real configuration.
class ClientIdentityTest < ActiveSupport::TestCase
  # A real Cloudflare address from the committed list, and a Render-internal hop.
  CLOUDFLARE = "172.68.174.106".freeze
  RENDER_INTERNAL = "10.28.65.0".freeze
  VISITOR = "184.23.124.45".freeze

  test "the visitor is seen through Cloudflare and Render's own hop" do
    assert_equal VISITOR, remote_ip("#{VISITOR}, #{CLOUDFLARE}, #{RENDER_INTERNAL}")
  end

  # Rails' own private ranges must survive: an enumerable replaces its list
  # rather than extending it, so dropping them would break Render's hop.
  test "private ranges are still trusted" do
    assert_equal VISITOR, remote_ip("#{VISITOR}, #{RENDER_INTERNAL}")
  end

  # A visitor can set X-Forwarded-For themselves; Cloudflare appends the address
  # it actually saw, so the spoofed entry sits to the left and is never reached.
  test "a spoofed forwarded-for does not win" do
    spoofed = "9.9.9.9"

    assert_equal VISITOR, remote_ip("#{spoofed}, #{VISITOR}, #{CLOUDFLARE}, #{RENDER_INTERNAL}")
  end

  test "two visitors behind the same edge are told apart" do
    other = "203.0.113.7"

    assert_not_equal remote_ip("#{VISITOR}, #{CLOUDFLARE}"),
                     remote_ip("#{other}, #{CLOUDFLARE}")
  end

  private
    def remote_ip(forwarded_for)
      env = Rack::MockRequest.env_for("/",
        "HTTP_X_FORWARDED_FOR" => forwarded_for, "REMOTE_ADDR" => RENDER_INTERNAL)

      ActionDispatch::RemoteIp.new(
        ->(_) { [ 200, {}, [] ] }, true,
        Rails.application.config.action_dispatch.trusted_proxies
      ).call(env)

      env["action_dispatch.remote_ip"].to_s
    end
end

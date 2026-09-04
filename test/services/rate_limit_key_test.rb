require "test_helper"

class RateLimitKeyTest < ActiveSupport::TestCase
  test "an IPv4 address is its own key" do
    assert_equal "184.23.124.45", RateLimitKey.for("184.23.124.45")
  end

  # A subscriber is typically handed a whole /64, so counting per exact address
  # would hand them a fresh allowance for every request.
  test "IPv6 addresses in one /64 share a key" do
    first = RateLimitKey.for("2001:db8:abcd:1234::1")
    second = RateLimitKey.for("2001:db8:abcd:1234:ffff:ffff:ffff:ffff")

    assert_equal first, second
  end

  test "IPv6 addresses in different /64s do not" do
    assert_not_equal RateLimitKey.for("2001:db8:abcd:1234::1"),
                     RateLimitKey.for("2001:db8:abcd:5678::1")
  end

  # Malformed input must still land in a bucket, or it escapes the limit.
  test "an unreadable address still counts against something" do
    assert_equal "unknown", RateLimitKey.for("not-an-address")
    assert_equal "unknown", RateLimitKey.for(nil)
    assert_equal "unknown", RateLimitKey.for("")
  end
end

require "test_helper"

class VisitorHashTest < ActiveSupport::TestCase
  # Countable: the whole point is that one visitor on one day is one value.
  test "the same address on the same day gives the same value" do
    assert_equal VisitorHash.for("203.0.113.9"), VisitorHash.for("203.0.113.9")
  end

  test "different addresses give different values" do
    assert_not_equal VisitorHash.for("203.0.113.9"), VisitorHash.for("203.0.113.10")
  end

  # Unlinkable: the key rotates at midnight, so yesterday's value cannot be
  # matched to today's — by anyone, including us. A visitor spanning midnight
  # therefore counts twice, which is the same property seen from the other side.
  test "the same address on a different day gives a different value" do
    today = VisitorHash.for("203.0.113.9", on: Date.new(2026, 9, 5))
    tomorrow = VisitorHash.for("203.0.113.9", on: Date.new(2026, 9, 6))

    assert_not_equal today, tomorrow
  end

  # Unreadable: this is the assertion that makes the retention promise survivable.
  test "the value never contains the address" do
    address = "203.0.113.9"

    assert_no_match(/203|113/, VisitorHash.for(address))
  end

  # Reuses RateLimitKey's masking, so a subscriber handed a whole /64 counts once
  # rather than once per address they happen to use.
  test "addresses in one IPv6 /64 give one value" do
    first = VisitorHash.for("2001:db8:1:2::1")
    second = VisitorHash.for("2001:db8:1:2::99ff")

    assert_equal first, second
  end

  test "addresses in different IPv6 /64s give different values" do
    assert_not_equal VisitorHash.for("2001:db8:1:2::1"), VisitorHash.for("2001:db8:1:3::1")
  end
end

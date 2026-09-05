require "test_helper"

class UsageEventTest < ActiveSupport::TestCase
  # AC4, asserted against the schema rather than against a row. A row-level check
  # only proves what today's code writes; this fails the day someone adds a column
  # that would make these rows identifying.
  test "no column can hold something identifying" do
    forbidden = UsageEvent.column_names.grep(/ip|address|filename|title|token|text|content|summary/i)

    assert_empty forbidden, "usage_events should hold nothing identifying, found: #{forbidden.inspect}"
  end

  test "records an upload with its size" do
    UsageEvent.record_upload(byte_size: 1234, address: "203.0.113.9")

    event = UsageEvent.sole
    assert_equal "upload", event.kind
    assert_equal 1234, event.byte_size
    assert_equal VisitorHash.for("203.0.113.9"), event.visitor_hash
  end

  test "records a refusal without a size" do
    UsageEvent.record_refusal(address: "203.0.113.9")

    event = UsageEvent.sole
    assert_equal "refusal", event.kind
    assert_nil event.byte_size
  end

  # The number is worth less than the thing it counts, so a broken insert must not
  # reach the caller — the upload it is counting has already succeeded.
  test "a failed insert is swallowed and logged, not raised" do
    assert_nothing_raised do
      UsageEvent.record_upload(byte_size: 1, address: nil)
      # kind is validated, so forcing an invalid one exercises the rescue
      UsageEvent.send(:record, "nonsense", "203.0.113.9")
    end

    assert_equal 1, UsageEvent.count, "only the valid row should have been written"
  end

  test "summary counts uploads, visitors and refusals separately" do
    UsageEvent.record_upload(byte_size: 1.megabyte, address: "203.0.113.1")
    UsageEvent.record_upload(byte_size: 3.megabytes, address: "203.0.113.1")
    UsageEvent.record_upload(byte_size: 2.megabytes, address: "203.0.113.2")
    UsageEvent.record_refusal(address: "203.0.113.3")

    summary = UsageEvent.summary

    assert_equal 3, summary[:uploads]
    assert_equal 3, summary[:visitors], "two uploaders plus the refused visitor"
    assert_equal 1, summary[:refusals]
    assert_equal 2.0, summary[:average_mb]
    assert_equal 3.0, summary[:maximum_mb]
  end

  # A refusal has no size, and a file rejected for being too large would otherwise
  # pin the maximum to the upload limit every time someone tried one.
  test "sizes describe accepted uploads only" do
    UsageEvent.record_upload(byte_size: 1.megabyte, address: "203.0.113.1")
    UsageEvent.record_refusal(address: "203.0.113.2")

    assert_equal 1.0, UsageEvent.summary[:maximum_mb]
  end

  test "summary reports zero sizes when nothing has been uploaded" do
    assert_equal 0.0, UsageEvent.summary[:average_mb]
    assert_equal 0.0, UsageEvent.summary[:maximum_mb]
  end
end

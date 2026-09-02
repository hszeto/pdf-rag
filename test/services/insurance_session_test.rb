require "test_helper"

class InsuranceSessionTest < ActiveSupport::TestCase
  test "a new session starts empty with every field present and nil" do
    session = InsuranceSession.new

    assert session.empty?
    assert_equal InsuranceSession::FIELD_KEYS.sort, session.structured_fields.keys.sort
    assert session.structured_fields.values.all?(&:nil?)
    assert_empty session.chat_history
  end

  test "round-trips through to_h and from_h" do
    original = InsuranceSession.new(
      session_id: "abc", status: "extracted", plain_summary: "Summary.",
      full_text: "Full text.", document_type: "Summary of Benefits"
    )
    original.structured_fields[:deductible] = "$1,500"
    original.add_turn("user", "What is my deductible?")
    original.add_turn("assistant", "It is $1,500.")

    restored = InsuranceSession.from_h(original.to_h)

    assert_equal "abc", restored.session_id
    assert_equal "extracted", restored.status
    assert_equal "$1,500", restored.field(:deductible)
    assert_equal 2, restored.chat_history.length
    assert_equal "What is my deductible?", restored.chat_history.first[:content]
  end

  test "from_h tolerates string keys and missing fields" do
    restored = InsuranceSession.from_h(
      "session_id" => "xyz",
      "status" => "uploaded",
      "structured_fields" => { "plan_name" => "ACME Gold" }
    )

    assert_equal "xyz", restored.session_id
    assert_equal "ACME Gold", restored.field(:plan_name)
    # Absent keys are still present as nil, so the view can render "not found"
    # rather than omitting the row entirely (R7.3).
    assert InsuranceSession::FIELD_KEYS.all? { |k| restored.structured_fields.key?(k) }
    assert_nil restored.field(:deductible)
  end

  test "from_h returns nil for blank input" do
    assert_nil InsuranceSession.from_h(nil)
    assert_nil InsuranceSession.from_h({})
  end

  test "status predicates" do
    assert InsuranceSession.new(status: "empty").empty?
    assert InsuranceSession.new(status: "extracted").extracted?
    assert InsuranceSession.new(status: "error").error?
  end
end

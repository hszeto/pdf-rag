require "test_helper"

class PlanScreenTest < ActionDispatch::IntegrationTest
  setup { Rails.cache.clear }

  # AC 12
  test "shows all nine facts in the order the spec fixes" do
    view_plan

    labels = css_select("dt").map { |n| n.text.strip }
    assert_equal [ "Name", "Plan Type", "Plan Name", "Insurance ID",
                   "Primary Care Copay", "Specialist Copay", "Deductible",
                   "Plan Year", "Customer Service Phone" ], labels
  end

  test "the presenter covers every field the session holds" do
    assert_equal InsuranceSession::FIELD_KEYS.sort, PlanPresenter.keys.sort,
      "a field added to the session must also get a row and a label"
  end

  test "renders the extracted values" do
    view_plan

    body = response.body
    assert_includes body, "Jane Q. Sample"
    assert_includes body, "$1,500"
    assert_includes body, "1-800-555-0142"
  end

  # AC 12: a fact the document did not contain is stated, never dropped.
  test "a missing fact says so rather than rendering blank" do
    view_plan(structured_fields: { "deductible" => "$1,500" })

    assert_equal 9, css_select("dt").length, "every row is present even when the value is not"
    assert_select "dd", text: /Not found in your document/
  end

  test "every single missing field still produces nine rows" do
    view_plan(structured_fields: {})

    assert_equal 9, css_select("dt").length
    assert_equal 9, css_select("dd").count { |n| n.text.include?(PlanPresenter::MISSING_TEXT) }
  end

  test "the plain summary is shown" do
    view_plan

    assert_select "h2", /In plain words/
    assert_includes response.body, "ACME Health Gold Advantage"
  end

  # R7.6 / D11
  test "says where the answers came from and points at a human" do
    view_plan

    assert_select "aside", /comes from the document you added/i
    assert_select "aside", /1-800-555-0142/
  end

  test "falls back to the insurance card when no phone was found" do
    view_plan(structured_fields: { "deductible" => "$1,500" })

    assert_select "aside", /call the number on your insurance card/i
    assert_select "aside", { text: /1-800-555-0142/, count: 0 }
  end

  test "admits it may have read something wrong" do
    view_plan

    assert_select "aside", /may have read something wrong/i
  end

  test "offers a way to remove the document" do
    view_plan

    assert_select "form[action=?][method=post]", session_path
  end

  # R7.1: no technical vocabulary anywhere the reader can see.
  test "the landing copy avoids technical words" do
    get root_path

    visible = Nokogiri::HTML(response.body).css("main").text
    %w[upload AI session cache token].each do |word|
      assert_no_match(/\b#{word}\b/i, visible, "#{word.inspect} should not appear in user-facing copy")
    end
  end

  private
    def view_plan(structured_fields: nil)
      payload = structured_fields ? gemini_analysis(structured_fields: structured_fields) : gemini_analysis
      upload_and_analyze("insurance_sample.pdf", payload)
      get root_path
    end
end

require "test_helper"

# AC 7: the policy is enumerable in one place, so what the app blocks can be
# read off a single list rather than inferred from scattered conditionals.
class PdfSafetyPolicyTest < ActiveSupport::TestCase
  test "every signal has a disposition and a plain-language label" do
    PdfSafetyPolicy::SIGNALS.each do |signal, config|
      assert_includes [ PdfSafetyPolicy::BLOCK, PdfSafetyPolicy::NOTE ], config[:disposition],
        "#{signal} has no usable disposition"
      assert config[:label].present?, "#{signal} has no label to show a reader"
      assert_no_match(/javascript|uri|action/i, config[:label],
        "#{signal}'s label reads like a spec term, not something to show a reader")
    end
  end

  test "the blocking set is exactly what we intend to refuse" do
    assert_equal %i[javascript launch_action executable_attachment].sort,
      PdfSafetyPolicy.blocking_signals.sort
  end

  test "links and ordinary attachments are noted, never blocking" do
    assert_equal %i[embedded_file external_link].sort, PdfSafetyPolicy.noted_signals.sort
    assert_not PdfSafetyPolicy.blocks?(:external_link)
    assert_not PdfSafetyPolicy.blocks?(:embedded_file)
  end

  test "executable extensions are recognised regardless of case or path" do
    %w[a.EXE b.Sh c.jar dir/d.ps1 e.bat].each do |name|
      assert PdfSafetyPolicy.executable?(name), "#{name} should be executable"
    end
  end

  test "document-like attachments are not executable" do
    %w[report.pdf notes.txt sheet.csv image.png Content\ Credentials].each do |name|
      assert_not PdfSafetyPolicy.executable?(name), "#{name} should not be executable"
    end
  end
end

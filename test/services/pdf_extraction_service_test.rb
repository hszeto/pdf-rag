require "test_helper"

class PdfExtractionServiceTest < ActiveSupport::TestCase
  include ActionDispatch::TestProcess::FixtureFile

  test "extracts the words from a text PDF" do
    text = PdfExtractionService.new(upload("insurance_sample.pdf")).extract!

    assert_includes text, "ACME HEALTH GOLD ADVANTAGE PLAN"
    assert_includes text, "$1,500"
    assert_includes text, "1-800-555-0142"
  end

  # D3: scanned and photographed documents are deferred, so a PDF that opens but
  # holds no words is a friendly dead end rather than a vision call.
  test "treats a PDF with almost no text as unreadable" do
    error = assert_raises(ProcessingError::Unreadable) do
      PdfExtractionService.new(upload("text_light.pdf")).extract!
    end

    assert_match(/could not find any words/i, error.user_message)
  end

  test "reports a truncated file as damaged" do
    error = assert_raises(ProcessingError::Damaged) do
      PdfExtractionService.new(upload("damaged.pdf")).extract!
    end

    assert_match(/may be damaged/i, error.user_message)
  end

  # AC 9: "locked" and "damaged" must be distinguishable. We cannot generate a
  # genuinely encrypted PDF here — there is no qpdf, gs or pdftk on this machine,
  # and a hand-built /Encrypt trailer fails as malformed before reaching the
  # encryption check — so the branch is driven through the injected reader.
  test "reports an encrypted file as locked, not damaged" do
    error = assert_raises(ProcessingError::Locked) do
      PdfExtractionService.new(upload("insurance_sample.pdf"), reader: raising_reader(PDF::Reader::EncryptedPDFError)).extract!
    end

    assert_match(/locked/i, error.user_message)
    assert_no_match(/damaged/i, error.user_message)
  end

  test "locked and damaged say different things to the user" do
    locked = ProcessingError::Locked.new.user_message
    damaged = ProcessingError::Damaged.new.user_message

    assert_not_equal locked, damaged
  end

  test "a malformed PDF raised by pdf-reader maps to damaged" do
    assert_raises(ProcessingError::Damaged) do
      PdfExtractionService.new(upload("insurance_sample.pdf"), reader: raising_reader(PDF::Reader::MalformedPDFError)).extract!
    end
  end

  # pdf-reader reaches plenty of broken input through generic exceptions; none of
  # them should escape as a 500.
  test "an unexpected reader failure still maps to damaged" do
    assert_raises(ProcessingError::Damaged) do
      PdfExtractionService.new(upload("insurance_sample.pdf"), reader: raising_reader(NoMethodError)).extract!
    end
  end


  # D12. A real 140-page policy took 15.8s to read whole and produced ~106,000
  # tokens; the cap brings that to ~2.3s and ~13,200. These assert the cap holds
  # rather than the timings, which vary by machine.
  test "reads no more than the page cap" do
    text = PdfExtractionService.new(upload("long_policy.pdf")).extract!

    assert_includes text, "PAGEMARKER001"
    assert_includes text, "PAGEMARKER020", "everything up to the cap should be read"
    assert_not_includes text, "PAGEMARKER021", "nothing past the cap should be read"
    assert_not_includes text, "PAGEMARKER030"
  end

  test "a document shorter than the cap is read whole" do
    text = PdfExtractionService.new(upload("insurance_sample.pdf")).extract!

    assert_includes text, "Member Services"
    assert_includes text, "Evidence of Coverage", "the last line of a short document is still read"
  end

  test "the cap bounds how much text a long document can contribute" do
    capped = PdfExtractionService.new(upload("long_policy.pdf")).extract!
    whole = PDF::Reader.new(file_fixture("long_policy.pdf").to_s).pages.map(&:text).join("\n")

    assert_operator capped.length, :<, whole.length
    assert_in_delta 20.0 / 30.0, capped.length.to_f / whole.length, 0.1,
      "roughly two thirds of a thirty page document should survive a twenty page cap"
  end
  private
    def upload(name) = fixture_file_upload(name, "application/pdf")

    # A stand-in for PDF::Reader that fails the way we need. No mocking library
    # exists in this project, so the seam is a plain object.
    def raising_reader(error_class)
      Class.new do
        define_method(:initialize) { |_io| raise error_class }
      end
    end
end

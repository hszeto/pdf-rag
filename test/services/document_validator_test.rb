require "test_helper"

class DocumentValidatorTest < ActiveSupport::TestCase
  include ActionDispatch::TestProcess::FixtureFile

  test "accepts a real PDF" do
    file = upload("insurance_sample.pdf")

    assert_equal file, DocumentValidator.new(file).validate!
  end

  # AC 7: the extension says PDF, the bytes say JPEG. The bytes win.
  test "rejects a JPEG wearing a .pdf extension" do
    error = assert_raises(ProcessingError::NotAPdf) do
      DocumentValidator.new(upload("actually_a_jpeg.pdf")).validate!
    end

    assert_match(/only read PDF files/i, error.user_message)
  end

  test "rejects a missing file" do
    assert_raises(ProcessingError::Missing) { DocumentValidator.new(nil).validate! }
    assert_raises(ProcessingError::Missing) { DocumentValidator.new("").validate! }
  end

  # AC 8: size comes from the tempfile's stat, so an oversized file is refused
  # without its contents ever being read.
  test "rejects a file over the limit without reading it" do
    reads = 0
    oversized = Struct.new(:size, :tempfile) do
      def blank? = false
    end.new(DocumentValidator::MAX_BYTES + 1, Object.new)

    oversized.tempfile.define_singleton_method(:read) { |*| reads += 1; "" }
    oversized.tempfile.define_singleton_method(:rewind) { 0 }

    error = assert_raises(ProcessingError::TooLarge) { DocumentValidator.new(oversized).validate! }

    assert_match(/too big/i, error.user_message)
    assert_equal 0, reads, "an oversized file must be rejected before being read"
  end

  test "accepts a file exactly at the limit" do
    at_limit = Struct.new(:size, :tempfile) do
      def blank? = false
    end.new(DocumentValidator::MAX_BYTES, StringIO.new("%PDF-1.4 rest of file"))

    assert_nothing_raised { DocumentValidator.new(at_limit).validate! }
  end

  test "rejects an empty file" do
    empty = Struct.new(:size, :tempfile) do
      def blank? = false
    end.new(0, StringIO.new(""))

    assert_raises(ProcessingError::NotAPdf) { DocumentValidator.new(empty).validate! }
  end

  test "leaves the file readable from the start for the next stage" do
    file = upload("insurance_sample.pdf")

    DocumentValidator.new(file).validate!

    assert_equal "%PDF-", file.tempfile.read(5), "the tempfile must be rewound after inspection"
  end

  private
    def upload(name) = fixture_file_upload(name, "application/pdf")
end

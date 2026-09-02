require "test_helper"

class DocumentsControllerTest < ActiveSupport::TestCase
  # The integration test asserts no tempfile survives the request, but Rack
  # unlinks multipart files at the end of the request anyway, so it passes
  # whether or not this app does anything. R3.5 asks for the document to be gone
  # the moment we are done with it rather than whenever the request happens to
  # finish, so the unlinking itself is verified directly here.
  test "discarding a tempfile closes and unlinks it immediately" do
    tempfile = Tempfile.new([ "probe", ".pdf" ])
    tempfile.write("%PDF-1.4")
    tempfile.flush
    path = tempfile.path
    uploaded = ActionDispatch::Http::UploadedFile.new(
      tempfile: tempfile, filename: "probe.pdf", type: "application/pdf"
    )

    assert File.exist?(path), "the probe file should exist before discarding"

    DocumentsController.new.send(:discard_tempfile, uploaded)

    assert_not File.exist?(path), "the document must be unlinked, not left for Rack to collect"
    assert tempfile.closed?, "the handle must be closed too"
  end

  test "discarding tolerates a missing or already-closed file" do
    tempfile = Tempfile.new([ "probe", ".pdf" ])
    uploaded = ActionDispatch::Http::UploadedFile.new(
      tempfile: tempfile, filename: "probe.pdf", type: "application/pdf"
    )
    tempfile.close!

    assert_nothing_raised { DocumentsController.new.send(:discard_tempfile, uploaded) }
  end

  test "discarding tolerates no file at all" do
    assert_nothing_raised do
      DocumentsController.new.send(:discard_tempfile, nil)
      DocumentsController.new.send(:discard_tempfile, "not a file")
    end
  end
end

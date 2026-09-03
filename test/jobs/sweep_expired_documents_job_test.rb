require "test_helper"

# Each document schedules its own removal, but a queue can lose a job. Those
# documents are already invisible to the app; the sweep is what stops them
# sitting on disk forever.
class SweepExpiredDocumentsJobTest < ActiveSupport::TestCase
  test "removes every expired document and leaves the rest alone" do
    expired = [ document(expires_at: 2.minutes.ago), document(expires_at: 1.hour.ago) ]
    live = document(expires_at: 30.minutes.from_now)

    SweepExpiredDocumentsJob.perform_now

    expired.each { |d| assert Document.where(id: d.id).none?, "expired document survived" }
    assert Document.exists?(live.id), "a live document was swept"
  end

  test "removes the files too" do
    doc = document(expires_at: 1.minute.ago)
    doc.file.attach(io: File.open(file_fixture("insurance_sample.pdf")),
                    filename: "d.pdf", content_type: "application/pdf")
    path = ActiveStorage::Blob.service.path_for(doc.file.blob.key)

    SweepExpiredDocumentsJob.perform_now

    assert_not File.exist?(path)
  end

  test "does nothing when there is nothing expired" do
    document(expires_at: 30.minutes.from_now)

    assert_nothing_raised { SweepExpiredDocumentsJob.perform_now }
    assert_equal 1, Document.count
  end


  # A deletion that did not finish leaves the row gone and the file behind,
  # which is precisely what the retention window exists to prevent.
  test "orphaned files are purged" do
    blob = ActiveStorage::Blob.create_and_upload!(
      io: File.open(file_fixture("insurance_sample.pdf")),
      filename: "orphan.pdf", content_type: "application/pdf"
    )
    blob.update!(created_at: 2.hours.ago)
    path = ActiveStorage::Blob.service.path_for(blob.key)

    SweepExpiredDocumentsJob.perform_now

    assert ActiveStorage::Blob.where(id: blob.id).none?
    assert_not File.exist?(path)
  end

  # A blob is unattached for a moment during upload; sweeping that would delete
  # a document out from under the request that is still storing it.
  test "a file still being attached is left alone" do
    blob = ActiveStorage::Blob.create_and_upload!(
      io: File.open(file_fixture("insurance_sample.pdf")),
      filename: "in-flight.pdf", content_type: "application/pdf"
    )

    SweepExpiredDocumentsJob.perform_now

    assert ActiveStorage::Blob.exists?(blob.id), "a freshly uploaded file was swept"
  end

  test "a file attached to a live document is left alone" do
    doc = document(expires_at: 30.minutes.from_now)
    doc.file.attach(io: File.open(file_fixture("insurance_sample.pdf")),
                    filename: "live.pdf", content_type: "application/pdf")
    doc.file.blob.update!(created_at: 2.hours.ago)

    SweepExpiredDocumentsJob.perform_now

    assert doc.reload.file.attached?
  end
  private
    def document(expires_at:)
      Document.create!(status: "ready", title: "doc.pdf", expires_at: expires_at)
    end
end

class AddScanFindingsToDocuments < ActiveRecord::Migration[8.1]
  # What screening found that did not block: links and ordinary attachments.
  # Stored on the record rather than carried in the session, so the reader can
  # come back to the document and still see them.
  def change
    add_column :documents, :links, :jsonb, null: false, default: []
    add_column :documents, :attachments, :jsonb, null: false, default: []
  end
end

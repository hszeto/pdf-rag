class CreateDocuments < ActiveRecord::Migration[8.1]
  def change
    create_table :documents do |t|
      t.string :status, null: false, default: "pending"
      t.string :title
      t.text :summary
      t.string :failure_reason

      # SHA-256 of the extracted text. Two uploads of the same document reuse
      # one set of embeddings rather than paying for them twice.
      t.string :content_hash

      # Retention is enforced by this column, not only by the sweep job. Queries
      # scope to it, so a job that never runs cannot expose an expired document —
      # it can only leak storage.
      t.datetime :expires_at, null: false

      t.timestamps
    end

    add_index :documents, :content_hash
    add_index :documents, :expires_at

    create_table :document_chunks do |t|
      t.references :document, null: false, foreign_key: { on_delete: :cascade }
      t.text :content, null: false
      t.integer :position, null: false

      # Where in the document this came from, so an answer can say so.
      t.integer :page

      t.timestamps
    end

    add_index :document_chunks, [ :document_id, :position ], unique: true
  end
end

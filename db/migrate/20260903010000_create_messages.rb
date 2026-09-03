class CreateMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :messages do |t|
      t.references :document, null: false, foreign_key: { on_delete: :cascade }
      t.string :role, null: false
      t.text :content, null: false

      # Where in the document an answer came from, so it can be shown alongside.
      t.jsonb :citations, null: false, default: []

      t.timestamps
    end

    add_index :messages, [ :document_id, :created_at ]
  end
end

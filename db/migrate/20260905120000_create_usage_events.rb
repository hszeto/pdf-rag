class CreateUsageEvents < ActiveRecord::Migration[8.1]
  def change
    # Deliberately no reference to documents. Every other table here is destroyed
    # with the document it belongs to; these rows have to outlive it, because the
    # whole point is to still know an upload happened thirty minutes later.
    create_table :usage_events do |t|
      # "upload" or "refusal" — counted separately, because a refused file never
      # became a document and folding them together would hide both numbers.
      t.string :kind, null: false

      # Null for refusals. Copied here at upload time because the only other
      # record of it lives on the Active Storage blob, which the sweep destroys.
      t.bigint :byte_size

      # A daily-rotating HMAC of the visitor's address, never the address. See
      # VisitorHash: countable, not reversible, and not linkable across days.
      t.string :visitor_hash, null: false

      t.timestamps
    end

    add_index :usage_events, :created_at
    add_index :usage_events, [ :visitor_hash, :created_at ]
  end
end

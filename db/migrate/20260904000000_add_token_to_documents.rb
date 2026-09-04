class AddTokenToDocuments < ActiveRecord::Migration[8.1]
  # Documents were addressed by their primary key, which is sequential, so one
  # reader could reach another's by counting. The token is what the URL carries
  # from here; the id stays internal and keeps crossing the queue.
  #
  # The column arrives nullable and is backfilled before the constraint, so no
  # existing document is briefly unreachable by the new route.
  def up
    add_column :documents, :token, :string

    Document.reset_column_information
    Document.where(token: nil).find_each do |document|
      document.update_columns(token: SecureRandom.base58(24))
    end

    change_column_null :documents, :token, false
    add_index :documents, :token, unique: true
  end

  def down
    remove_index :documents, :token
    remove_column :documents, :token
  end
end

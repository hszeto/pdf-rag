class AddEmbeddingsToDocumentChunks < ActiveRecord::Migration[8.1]
  # Separate from the table creation because the column type comes from the
  # pgvector extension, and the dimension is fixed by the embedding model
  # (gemini-embedding-001 returns 3072). Changing it later means re-embedding
  # every document.
  def change
    add_column :document_chunks, :embedding, :vector, limit: GeminiClient::EMBEDDING_DIMENSIONS
  end
end

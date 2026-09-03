class DocumentChunk < ApplicationRecord
  belongs_to :document

  # Cosine distance, because the embeddings are direction-normalised and we care
  # about what a passage is about rather than how long it is.
  has_neighbors :embedding, dimensions: GeminiClient::EMBEDDING_DIMENSIONS

  validates :content, presence: true
  validates :position, presence: true

  scope :ordered, -> { order(:position) }
  scope :embedded, -> { where.not(embedding: nil) }

  # Where this passage came from, for citing an answer.
  def location
    page.present? ? "page #{page}" : "part #{position + 1}"
  end
end

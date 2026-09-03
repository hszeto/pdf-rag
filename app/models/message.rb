class Message < ApplicationRecord
  belongs_to :document

  ROLES = %w[user assistant].freeze
  validates :role, inclusion: { in: ROLES }
  validates :content, presence: true

  scope :ordered, -> { order(:created_at, :id) }

  def asked? = role == "user"
  def answered? = role == "assistant"
end

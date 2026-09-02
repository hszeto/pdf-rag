# Value object over the hash held in the cache. There is no database in this app
# (see CLAUDE.md), so Active Model provides the attribute layer.
#
# The cache stores a plain Hash rather than a marshalled instance of this class:
# a marshalled custom class fails to load after a code reload in development, and
# after a deploy while older entries are still live. Since the cache is the only
# datastore here, that failure mode would lose a user's document outright.
class InsuranceSession
  include ActiveModel::Model
  include ActiveModel::Attributes

  # "empty" covers a session created on first visit that has no document yet;
  # "analyzing" covers the window while the background job is reading it. The
  # spec lists only the three settled states.
  STATUSES = %w[empty uploaded analyzing extracted error].freeze

  FIELD_KEYS = %i[
    member_name plan_type plan_name insurance_id
    copay_primary_care copay_specialist deductible plan_year
    customer_service_phone
  ].freeze

  attribute :session_id, :string
  attribute :status, :string, default: "empty"
  attribute :plain_summary, :string
  attribute :full_text, :string
  attribute :document_type, :string
  # What went wrong, when it went wrong inside the job rather than the request.
  attribute :error_message, :string
  attribute :analyzing_since, :datetime
  attribute :created_at, :datetime
  attribute :last_active_at, :datetime

  attr_accessor :structured_fields, :chat_history

  def initialize(attrs = {})
    super
    self.structured_fields ||= FIELD_KEYS.index_with(nil)
    self.chat_history ||= []
  end

  def self.from_h(hash)
    return nil if hash.blank?

    attrs = hash.deep_symbolize_keys
    fields = attrs.delete(:structured_fields) || {}
    history = attrs.delete(:chat_history) || []

    new(**attrs).tap do |s|
      s.structured_fields = FIELD_KEYS.index_with { |k| fields[k] }
      s.chat_history = history
    end
  end

  def to_h
    attributes.symbolize_keys.merge(
      structured_fields: structured_fields,
      chat_history: chat_history
    )
  end

  def empty? = status == "empty"
  def analyzing? = status == "analyzing"
  def extracted? = status == "extracted"
  def error? = status == "error"

  # Nil fields render as an explicit "not found" message rather than a blank row,
  # so the user is never left wondering whether we simply failed to show it (R7.3).
  def field(key) = structured_fields[key.to_sym]

  def add_turn(role, content)
    chat_history << { role: role.to_s, content: content.to_s }
  end
end

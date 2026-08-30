# frozen_string_literal: true

class IdempotencyKey < ApplicationRecord
  belongs_to :user, optional: true

  DEFAULT_TTL = 24.hours

  STATUSES = %w[processing completed failed].freeze
  enum :status, STATUSES.index_by(&:itself), validate: true

  validates :key, presence: true, length: { maximum: 255 }
  validates :request_path, :request_method, :request_fingerprint, presence: true

  scope :live, -> { where(expires_at: Time.current..) }

  before_validation { self.expires_at ||= DEFAULT_TTL.from_now }

  def self.fingerprint(payload) = OpenSSL::Digest::SHA256.hexdigest(payload.to_s)

  def matches_request?(fingerprint) = request_fingerprint == fingerprint
end

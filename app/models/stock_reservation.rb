# frozen_string_literal: true

class StockReservation < ApplicationRecord
  belongs_to :stock_item
  belongs_to :user, optional: true
  belongs_to :reference, polymorphic: true, optional: true

  STATUSES = %w[held committed released expired].freeze
  DEFAULT_TTL = 30.minutes

  # ┌────────────────────────────────────────────────────────────────────────┐
  # │ TRAMPA DE `enum`: Rails genera un método bang por cada valor            │
  # │ (`held!`, `committed!`, ...) y explota si pisa uno propio.              │
  # │ `committed!` YA EXISTE en ActiveRecord (lo usa el manejo de             │
  # │ transacciones para disparar los after_commit). Rails te avisa con un    │
  # │ ArgumentError al bootear — mejor eso que un bug silencioso.             │
  # │                                                                        │
  # │ Solución: `prefix: :status` => `status_held?`, `status_committed!`.     │
  # │ Y abajo definimos alias legibles para los predicados (no para los       │
  # │ bang, que son justamente los que colisionan).                           │
  # └────────────────────────────────────────────────────────────────────────┘
  enum :status, STATUSES.index_by(&:itself), validate: true, prefix: :status

  def held?      = status_held?
  def committed? = status_committed?
  def released?  = status_released?
  def expired?   = status_expired?

  validates :quantity, numericality: { greater_than: 0, only_integer: true }
  validates :expires_at, presence: true

  before_validation { self.expires_at ||= DEFAULT_TTL.from_now }

  scope :active,  -> { where(status: "held") }
  # Rango sin comienzo (Ruby 2.7+): equivale a `expires_at <= now`.
  scope :expired_now, -> { active.where(expires_at: ..Time.current) }
  scope :for_reference, ->(ref) { where(reference_type: ref.class.name, reference_id: ref.id) }

  delegate :product, :warehouse, to: :stock_item

  def active? = held?
  def expired_now? = held? && expires_at <= Time.current
  def terminal? = committed? || released? || expired?

  def to_s = "#{quantity} x #{product.sku} (#{status})"
end

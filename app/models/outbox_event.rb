# frozen_string_literal: true

# Ver el comentario largo en db/migrate/*_create_outbox_events.rb y docs/07.
class OutboxEvent < ApplicationRecord
  MAX_ATTEMPTS = 10

  validates :aggregate_type, :aggregate_id, :event_type, :occurred_at, presence: true

  scope :pending,   -> { where(published_at: nil) }
  scope :published, -> { where.not(published_at: nil) }
  scope :stuck,     -> { pending.where(attempts: MAX_ATTEMPTS..) }

  # ---------------------------------------------------------------------------
  # `FOR UPDATE SKIP LOCKED` es LA primitiva de colas en SQL (Postgres 9.5+).
  #
  #   FOR UPDATE          -> bloqueo exclusivo de las filas seleccionadas
  #   SKIP LOCKED         -> en vez de esperar, SALTEÁ las que ya están tomadas
  #
  # Resultado: N workers pueden hacer esta misma query en paralelo y cada uno
  # se lleva un lote DISTINTO, sin coordinación externa, sin Redis, sin
  # deadlocks y sin que ninguno espere. Es exactamente el mecanismo que usan
  # Solid Queue, Que y GoodJob por debajo.
  #
  # Sin SKIP LOCKED, el worker 2 esperaría a que el 1 termine su transacción:
  # la cola se serializaría y no escalarías agregando workers.
  # ---------------------------------------------------------------------------
  def self.claim_batch(limit: 500)
    pending
      .where(attempts: ...MAX_ATTEMPTS)
      .order(:id)
      .limit(limit)
      .lock("FOR UPDATE SKIP LOCKED")
  end

  def mark_published! = update!(published_at: Time.current, last_error: nil)

  def mark_failed!(error)
    update!(attempts: attempts + 1, last_error: "#{error.class}: #{error.message}".truncate(1000))
  end

  def published? = published_at.present?

  # El payload que efectivamente sale hacia el broker / webhook.
  def to_message
    {
      event_id:,
      event_type:,
      event_version:,
      aggregate: { type: aggregate_type, id: aggregate_id },
      occurred_at: occurred_at.iso8601(3),
      data: payload,
      metadata:
    }
  end
end

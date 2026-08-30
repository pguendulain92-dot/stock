# frozen_string_literal: true

# ==============================================================================
# ApiToken — credencial para la API JSON.
#
# El token EN CLARO existe UNA sola vez: en el objeto devuelto por `.issue!`.
# Después sólo queda el digest. Si el usuario lo pierde, se genera otro. Es
# exactamente cómo funcionan los personal access tokens de GitHub.
# ==============================================================================
class ApiToken < ApplicationRecord
  belongs_to :user

  # Scopes de autorización, estilo OAuth. El controller exige el scope que
  # corresponde a la acción antes de dejar pasar.
  SCOPES = %w[
    stock:read stock:write
    catalog:read catalog:write
    transfers:write purchases:write
    admin
  ].freeze

  PREFIX = "stk"
  TOKEN_BYTES = 32   # 256 bits de entropía: imposible de adivinar

  # `attr_reader` virtual: sólo vive en memoria, nunca se persiste.
  attr_reader :plaintext

  validates :name, presence: true, length: { maximum: 80 }
  validate :scopes_must_be_known

  scope :active, -> { where(revoked_at: nil).where("expires_at IS NULL OR expires_at > ?", Time.current) }

  class << self
    # Genera un token nuevo. Devuelve el registro con `plaintext` seteado.
    def issue!(user:, name:, scopes:, expires_in: nil)
      raw = "#{PREFIX}_#{SecureRandom.urlsafe_base64(TOKEN_BYTES)}"

      token = create!(
        user:,
        name:,
        scopes: Array(scopes),
        token_digest: digest(raw),
        token_prefix: raw.first(12),
        expires_at: expires_in&.from_now
      )
      token.instance_variable_set(:@plaintext, raw)
      token
    end

    # SHA-256, no bcrypt: ver el comentario de la migración. Un token de 256
    # bits no es fuerza-bruteable, y esto corre en CADA request.
    def digest(raw) = OpenSSL::Digest::SHA256.hexdigest(raw)

    # Búsqueda en tiempo constante respecto del contenido: hasheamos el input y
    # buscamos por índice único. No hay comparación de strings secretos en Ruby,
    # así que no hay timing attack posible sobre el token.
    def authenticate(raw)
      return nil if raw.blank?

      active.find_by(token_digest: digest(raw))
    end
  end

  def expired? = expires_at.present? && expires_at <= Time.current
  def revoked? = revoked_at.present?
  def usable? = !expired? && !revoked?

  def permits?(scope)
    scopes.include?("admin") || scopes.include?(scope.to_s)
  end

  def revoke! = update!(revoked_at: Time.current)

  # Registrar el uso en cada request sería un UPDATE por request (contención en
  # la fila + WAL). `update_columns` saltea validaciones y callbacks, y sólo lo
  # hacemos si pasó más de un minuto: throttling de escrituras.
  def touch_usage!
    return if last_used_at.present? && last_used_at > 1.minute.ago

    update_columns(last_used_at: Time.current, requests_count: requests_count + 1)
  end

  private

  def scopes_must_be_known
    unknown = scopes - SCOPES
    errors.add(:scopes, "desconocidos: #{unknown.join(', ')}") if unknown.any?
  end
end

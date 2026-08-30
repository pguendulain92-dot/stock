# frozen_string_literal: true

class User < ApplicationRecord
  # `has_secure_password` (ActiveModel) agrega:
  #   - los accessors virtuales `password` y `password_confirmation`
  #   - la validación de confirmación y de largo máximo (72 bytes, límite de bcrypt)
  #   - el método `authenticate(pass)` que devuelve el user o false
  # Guarda un bcrypt en `password_digest`. El "cost" sale de
  # ActiveModel::SecurePassword.min_cost (bajo en test para no frenar la suite).
  has_secure_password

  has_many :sessions, dependent: :destroy
  has_many :api_tokens, dependent: :destroy

  # `dependent: :nullify` -> al borrar el usuario, sus movimientos quedan con
  # user_id NULL pero NO se borran. Nunca destruyas historia contable.
  has_many :stock_movements, dependent: :nullify
  has_many :requested_transfers, class_name: "StockTransfer",
           foreign_key: :requested_by_id, dependent: :restrict_with_error, inverse_of: :requested_by

  # `normalizes` (Rails 7.1+) aplica la transformación en la asignación Y en
  # las queries: `User.find_by(email_address: "  ANA@X.COM ")` funciona.
  # Antes esto se hacía con un before_validation y las búsquedas no lo aplicaban.
  normalizes :email_address, with: ->(e) { e.strip.downcase }
  normalizes :name, with: ->(n) { n.to_s.squish }

  # ENUM CON BACKING DE STRING.
  #
  # Con `enum :role, { admin: 0, ... }` (entero) Rails guarda el ordinal. Si
  # alguien reordena las claves, los datos históricos cambian de significado en
  # silencio. Es un bug de datos irreversible y silencioso.
  # Con array/hash de strings, la base guarda "admin" y ese riesgo desaparece.
  # El CHECK constraint de la migración es el cinturón de seguridad.
  #
  # `validate: true` hace que un rol inválido dé un error de validación
  # (`errors[:role]`) en vez de un ArgumentError. Preferís lo primero en un form.
  enum :role, %w[admin manager operator viewer].index_by(&:itself), validate: true

  validates :email_address, presence: true,
            format: { with: URI::MailTo::EMAIL_REGEXP },
            # `case_sensitive: false` es redundante con citext, pero deja el
            # intento explícito. OJO: esta validación NO es a prueba de carreras;
            # la garantía real es el índice UNIQUE (ver docs/10).
            uniqueness: { case_sensitive: false }
  validates :name, length: { maximum: 120 }

  scope :active, -> { where(active: true) }

  # Métodos de consulta de permisos. Los usa Pundit desde las policies.
  # `>=` sobre el índice del rol implementa una jerarquía simple.
  ROLE_RANK = { "viewer" => 0, "operator" => 1, "manager" => 2, "admin" => 3 }.freeze

  def at_least?(other_role) = ROLE_RANK.fetch(role) >= ROLE_RANK.fetch(other_role.to_s)

  def to_s = name.presence || email_address
end

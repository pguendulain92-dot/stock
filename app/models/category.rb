# frozen_string_literal: true

class Category < ApplicationRecord
  MAX_DEPTH = 5

  belongs_to :parent, class_name: "Category", optional: true, inverse_of: :children
  has_many :children, class_name: "Category", foreign_key: :parent_id,
           dependent: :restrict_with_error, inverse_of: :parent
  has_many :products, dependent: :restrict_with_error

  normalizes :slug, with: ->(s) { s.to_s.parameterize }

  validates :name, presence: true, length: { maximum: 120 }
  validates :slug, presence: true, uniqueness: true
  validate :parent_cannot_be_self_or_descendant

  before_validation :assign_slug, on: :create
  before_save :recompute_path

  scope :roots, -> { where(parent_id: nil) }
  scope :active, -> { where(active: true) }

  # Trae TODO el subárbol con UNA query gracias al path materializado.
  # La alternativa recursiva pura está en `self.subtree_sql` más abajo.
  def subtree = self.class.where("path LIKE ?", "#{path}%")

  # ---------------------------------------------------------------------------
  # La misma consulta con CTE recursiva, sin depender del path materializado.
  # Es la forma "pura" en SQL y vale la pena saber escribirla en una entrevista.
  #
  #   WITH RECURSIVE tree AS (
  #     SELECT * FROM categories WHERE id = ?          -- caso base
  #     UNION ALL
  #     SELECT c.* FROM categories c
  #       JOIN tree t ON c.parent_id = t.id            -- paso recursivo
  #   )
  #   SELECT * FROM tree;
  #
  # `find_by_sql` devuelve modelos reales. Ojo con la inyección: usá
  # sanitize_sql_array SIEMPRE que haya un valor del usuario.
  # ---------------------------------------------------------------------------
  def subtree_recursive
    sql = self.class.sanitize_sql_array([ <<~SQL.squish, id ])
      WITH RECURSIVE tree AS (
        SELECT categories.* FROM categories WHERE categories.id = ?
        UNION ALL
        SELECT c.* FROM categories c INNER JOIN tree t ON c.parent_id = t.id
      )
      SELECT * FROM tree
    SQL
    self.class.find_by_sql(sql)
  end

  def ancestors
    return self.class.none if parent_id.nil?

    self.class.where(slug: path.split("/")[0..-2])
  end

  def root? = parent_id.nil?

  def to_s = name

  private

  def assign_slug
    self.slug = name.to_s.parameterize if slug.blank?
  end

  def recompute_path
    self.depth = parent ? parent.depth + 1 : 0
    self.path  = parent ? "#{parent.path}/#{slug}" : slug.to_s
  end

  def parent_cannot_be_self_or_descendant
    return if parent_id.blank?

    errors.add(:parent, "no puede ser sí misma") if parent_id == id
    errors.add(:parent, "no puede ser una descendiente") if persisted? && parent&.path&.start_with?("#{path}/")
    errors.add(:base, "el árbol no puede tener más de #{MAX_DEPTH} niveles") if parent && parent.depth >= MAX_DEPTH
  end
end

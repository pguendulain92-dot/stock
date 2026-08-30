# frozen_string_literal: true

module Products
  # ============================================================================
  # Búsqueda de productos con filtros combinables.
  #
  # PUNTOS DE OPTIMIZACIÓN QUE HAY QUE SABER EXPLICAR:
  #
  # 1) `includes(:category)` -> evita el N+1 al renderizar el nombre de la
  #    categoría de cada producto. Sin esto: 1 query + N queries.
  #
  # 2) `ILIKE '%texto%'` normalmente hace Seq Scan porque el comodín inicial
  #    inutiliza un índice B-tree. Con la extensión pg_trgm y un índice GIN
  #    (index_products_on_name_trgm), Postgres SÍ puede usar índice.
  #
  # 3) `sanitize_sql_like` escapa `%` y `_` del input. Sin eso, un usuario
  #    escribe "%" y te fuerza un escaneo completo de la tabla (DoS barato).
  #
  # 4) Ordenamos por una columna INDEXADA y desempatamos por `id`. Sin el
  #    desempate, dos filas con el mismo `name` pueden salir en distinto orden
  #    en páginas distintas => ves un producto dos veces o nunca. Es el bug de
  #    paginación más común y más difícil de creer cuando lo reportan.
  # ============================================================================
  class Search < ApplicationQuery
    SORTS = {
      "name" => { name: :asc, id: :asc },
      "sku" => { sku: :asc, id: :asc },
      "newest" => { created_at: :desc, id: :desc },
      "price" => { price_cents: :desc, id: :asc }
    }.freeze

    def initialize(term: nil, category_id: nil, supplier_id: nil, active: nil,
                   include_discarded: false, sort: "name", scope: Product.all)
      @term = term
      @category_id = category_id
      @supplier_id = supplier_id
      @active = active
      @include_discarded = include_discarded
      @sort = SORTS.key?(sort.to_s) ? sort.to_s : "name"
      @scope = scope
    end

    def call
      relation = @scope
      relation = relation.kept unless @include_discarded
      relation = apply_term(relation)
      relation = apply_if(relation, @category_id) { |r, v| r.where(category_id: v) }
      relation = apply_if(relation, @supplier_id) { |r, v| by_supplier(r, v) }
      relation = relation.where(active: @active) unless @active.nil?

      relation.includes(:category).order(SORTS.fetch(@sort))
    end

    private

    def apply_term(relation)
      return relation if @term.blank?

      pattern = "%#{Product.sanitize_sql_like(@term.strip)}%"

      # Buscar por SKU exacto primero es muchísimo más barato (índice único).
      # Sólo caemos al trigram si no parece un SKU.
      if @term.match?(/\A[A-Za-z0-9._-]{2,32}\z/)
        relation.where("sku = :exact OR name ILIKE :pattern OR barcode = :exact",
                       exact: @term.strip.upcase, pattern:)
      else
        relation.where("name ILIKE :pattern OR description ILIKE :pattern", pattern:)
      end
    end

    # `where(id: subquery)` genera un IN (SELECT ...) que Postgres suele
    # convertir en semi-join. Es MEJOR que `joins(:product_suppliers)` acá
    # porque un join uno-a-muchos DUPLICA filas del lado izquierdo si un
    # producto tiene 3 proveedores, y después tenés que meter un `.distinct`
    # que fuerza un sort/hash agregado carísimo.
    def by_supplier(relation, supplier_id)
      relation.where(id: ProductSupplier.where(supplier_id:).select(:product_id))
    end
  end
end

# frozen_string_literal: true

module Api
  module V1
    class ProductsController < BaseController
      requires_scope "catalog:read", only: %i[index show]
      requires_scope "catalog:write", only: %i[create update destroy]
      idempotent only: %i[create]

      def index
        scope = policy_scope(Product)
        products = Products::Search.call(
          term: params[:q], category_id: params[:category_id], supplier_id: params[:supplier_id],
          active: boolean_param(:active), sort: params[:sort].presence || "name", scope:
        )
        pagy, records = paginate(products)

        # ── ESTA ES LA LÍNEA QUE EVITA EL N+1 DE AGREGACIÓN ──────────────────
        # Calculamos la disponibilidad de LOS 25 productos de la página con UNA
        # query agregada, y se la pasamos al serializer. La alternativa ingenua
        # (`product.total_available` dentro del serializer) serían 25 queries
        # extra por página. Ver docs/04.
        availability = StockItems::Availability.call(product_ids: records.map(&:id))

        pagy_headers_merge(pagy)
        render json: {
          data: records.map { |p| ProductSerializer.new(p, availability: availability[p.id]).as_json },
          meta: { page: pagy.page, limit: pagy.limit, total_count: pagy.count,
                  total_pages: pagy.pages, next_page: pagy.next, prev_page: pagy.prev }
        }
      end

      def show
        product = Product.includes(:category).find_by!(sku: params[:id].to_s.upcase)
        authorize product
        availability = StockItems::Availability.call(product_ids: [ product.id ])
        render json: { data: ProductSerializer.new(product, availability: availability[product.id]).as_json }
      end

      def create
        product = Product.new(product_params)
        authorize product
        product.save!
        render json: { data: ProductSerializer.new(product).as_json }, status: :created
      end

      def update
        product = Product.find_by!(sku: params[:id].to_s.upcase)
        authorize product

        # OPTIMISTIC LOCKING SOBRE HTTP.
        # El cliente manda el lock_version que leyó. Si otro lo modificó desde
        # entonces, Rails tira StaleObjectError y devolvemos 409. Es el mismo
        # mecanismo que If-Match/ETag en REST, y evita el "last write wins"
        # silencioso que hace que dos operadores se pisen las ediciones.
        product.lock_version = params[:lock_version] if params[:lock_version].present?
        product.update!(product_params)
        render json: { data: ProductSerializer.new(product).as_json }
      end

      def destroy
        product = Product.find_by!(sku: params[:id].to_s.upcase)
        authorize product
        # Soft delete: nunca borramos algo referenciado por el ledger.
        product.discard!
        head :no_content
      end

      private

      # ── STRONG PARAMETERS ────────────────────────────────────────────────────
      # Es la defensa contra MASS ASSIGNMENT. Sin esto, un atacante manda
      # {"product": {"name": "x", "id": 1, "created_at": "..."}} y escribe campos
      # que nunca pensaste exponer. `permit` es una ALLOW-LIST explícita: lo que
      # no está, no pasa. (Rails aprendió esto por las malas: en 2012 alguien se
      # dio permisos de admin en el repo de Rails en GitHub explotando
      # exactamente este agujero.)
      def product_params
        params.require(:product).permit(
          :sku, :name, :description, :barcode, :category_id, :unit,
          :cost_cents, :price_cents, :currency, :weight_grams, :active
        )
      end

      # `params[:active]` llega como String. "false" es truthy en Ruby: un
      # `if params[:active]` daría true para "false". Hay que convertir SIEMPRE.
      def boolean_param(name)
        return nil if params[name].blank?

        ActiveModel::Type::Boolean.new.cast(params[name])
      end
    end
  end
end

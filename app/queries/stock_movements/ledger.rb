# frozen_string_literal: true

module StockMovements
  # ============================================================================
  # El libro mayor filtrado, con PAGINACIÓN POR KEYSET (cursor).
  #
  # OFFSET vs KEYSET — pregunta clásica de entrevista sobre performance:
  #
  #   OFFSET 100000 LIMIT 20
  #     Postgres tiene que GENERAR y DESCARTAR 100.000 filas para devolverte 20.
  #     El costo crece linealmente con el número de página: la página 1 vuela,
  #     la 5000 tarda segundos. Además, si alguien inserta una fila mientras
  #     paginás, se te desplaza todo y ves filas repetidas o te salteás otras.
  #
  #   KEYSET (cursor)
  #     WHERE (occurred_at, id) < (:last_occurred_at, :last_id)
  #     ORDER BY occurred_at DESC, id DESC LIMIT 20
  #     Postgres SALTA directo con el índice. Es O(log n) para CUALQUIER página,
  #     y como el cursor apunta a una fila concreta, insertar no desplaza nada.
  #
  #   La comparación de TUPLAS `(a, b) < (x, y)` es SQL estándar y hace
  #   exactamente lo que querés (compara a, y sólo si empata compara b). Es lo
  #   que permite que el índice compuesto (occurred_at DESC, id DESC) sirva
  #   para todo el WHERE de una sola pasada.
  #
  #   Contra: no podés "saltar a la página 37". Para un ledger infinito eso es
  #   irrelevante (nadie salta a la página 37 de un log).
  # ============================================================================
  class Ledger < ApplicationQuery
    DEFAULT_LIMIT = 50
    MAX_LIMIT = 200

    # `preload:` permite pedir SÓLO las asociaciones que el que llama va a
    # renderizar. El dashboard, por ejemplo, no muestra el usuario: cargarlo
    # sería una query de más en cada visita. Un query object compartido entre
    # varias vistas necesita este parámetro, o precarga de más para unas o de
    # menos para otras.
    DEFAULT_PRELOAD = %i[product warehouse user].freeze

    def initialize(product_id: nil, warehouse_id: nil, stock_item_id: nil,
                   kinds: nil, from: nil, to: nil, user_id: nil,
                   cursor: nil, limit: DEFAULT_LIMIT, preload: DEFAULT_PRELOAD)
      @product_id = product_id
      @warehouse_id = warehouse_id
      @stock_item_id = stock_item_id
      @kinds = Array(kinds).presence
      @from = from
      @to = to
      @user_id = user_id
      @cursor = cursor
      @limit = limit.to_i.clamp(1, MAX_LIMIT)
      @preload = Array(preload)
    end

    def call
      relation = StockMovement.all
      relation = relation.where(product_id: @product_id) if @product_id
      relation = relation.where(warehouse_id: @warehouse_id) if @warehouse_id
      relation = relation.where(stock_item_id: @stock_item_id) if @stock_item_id
      relation = relation.where(user_id: @user_id) if @user_id
      relation = relation.where(kind: @kinds) if @kinds
      relation = relation.where(occurred_at: @from..) if @from
      relation = relation.where(occurred_at: ..@to) if @to
      relation = apply_cursor(relation)

      relation.includes(*@preload)
              .order(occurred_at: :desc, id: :desc)
              .limit(@limit)
    end

    # Codifica el cursor de la última fila para devolvérselo al cliente.
    # Base64 de un JSON: es opaco para el cliente (no puede "adivinar" que hay
    # detrás y romperse cuando cambiemos el criterio de orden).
    def self.encode_cursor(movement)
      return nil if movement.nil?

      Base64.urlsafe_encode64(
        { t: movement.occurred_at.iso8601(6), i: movement.id }.to_json, padding: false
      )
    end

    private

    def apply_cursor(relation)
      return relation if @cursor.blank?

      decoded = JSON.parse(Base64.urlsafe_decode64(@cursor))
      relation.where(
        "(stock_movements.occurred_at, stock_movements.id) < (?, ?)",
        Time.zone.parse(decoded.fetch("t")), decoded.fetch("i")
      )
    rescue ArgumentError, JSON::ParserError, KeyError
      # Un cursor corrupto no debe tirar un 500: lo ignoramos y devolvemos la
      # primera página. (Y lo logueamos, porque suele indicar un bug del cliente.)
      Rails.logger.warn("[Ledger] cursor inválido: #{@cursor.inspect}")
      relation
    end
  end
end

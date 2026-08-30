# frozen_string_literal: true

module Stock
  # ============================================================================
  # ApplyMovement — el ÚNICO lugar del sistema que cambia una cantidad de stock.
  #
  # Todos los demás services (Receive, Issue, Adjust, Transfer, CommitReservation)
  # delegan acá. Eso es SRP llevado en serio: si el día de mañana hay que
  # agregar una regla a toda operación de stock (por ejemplo, prohibir movimientos
  # sobre productos dados de baja, o loguear a un sistema fiscal), se toca UN
  # archivo, y todo lo demás la hereda.
  #
  # Cada llamada, dentro de UNA transacción:
  #   1. Chequea idempotencia (si vino una clave).
  #   2. Bloquea la fila de stock_items con SELECT ... FOR UPDATE.
  #   3. Valida las invariantes contra el estado YA BLOQUEADO.
  #   4. Actualiza la proyección (stock_items).
  #   5. Escribe el asiento inmutable en el ledger (stock_movements).
  #   6. Registra el evento de dominio en el outbox.
  #
  # POR QUÉ EL LOCK Y POR QUÉ ADENTRO DE LA TRANSACCIÓN:
  #
  #   Sin lock, dos requests concurrentes hacen esto:
  #     T1: SELECT quantity_on_hand -> 10
  #     T2: SELECT quantity_on_hand -> 10
  #     T1: UPDATE ... SET quantity_on_hand = 10 - 7   -> 3
  #     T2: UPDATE ... SET quantity_on_hand = 10 - 7   -> 3   ¡vendiste 14 de 10!
  #   Es la "lost update" de manual. Postgres en READ COMMITTED (el default) NO
  #   te protege de esto: cada UPDATE ve la fila más nueva, pero el cálculo lo
  #   hiciste en Ruby con un valor viejo.
  #
  #   `SELECT ... FOR UPDATE` hace que T2 se quede esperando en el SELECT hasta
  #   que T1 commitee, y entonces T2 lee 3, no 10. La ventana desaparece.
  #
  #   El CHECK constraint `quantity_on_hand >= 0` es la última red: aunque
  #   alguien se saltee este service, la base rechaza el estado inválido.
  # ============================================================================
  class ApplyMovement < ApplicationService
    # DEPENDENCY INVERSION: `event_recorder` y `clock` entran por el constructor
    # con un default sensato. En los tests inyectás un NullRecorder y un reloj
    # congelado; en producción no escribís nada extra. Sin framework de DI.
    def initialize(stock_item:, kind:, quantity:, reserved_delta: 0,
                   user: nil, reference: nil, reason: nil, unit_cost_cents: nil,
                   idempotency_key: nil, occurred_at: nil, metadata: {},
                   event_recorder: Outbox::Recorder.new, clock: Time)
      @stock_item_id = stock_item.is_a?(StockItem) ? stock_item.id : stock_item
      @kind = kind.to_s
      @quantity = Integer(quantity)
      @reserved_delta = Integer(reserved_delta)
      @user = user
      @reference = reference
      @reason = reason
      @unit_cost_cents = unit_cost_cents
      @idempotency_key = idempotency_key.presence
      @occurred_at = occurred_at
      @metadata = metadata
      @event_recorder = event_recorder
      @clock = clock
    end

    def call
      transactional do
        # Idempotencia: si ya procesamos esta clave, devolvemos el movimiento
        # original. Todavía no escribimos nada, así que salir acá es seguro.
        if (existing = replayed_movement)
          next success(existing)
        end

        item = lock_stock_item!
        validate!(item)

        apply_to(item)
        movement = write_ledger_entry(item)
        publish_event(item, movement)

        success(movement)
      end
    end

    private

    attr_reader :kind, :quantity, :reserved_delta, :user, :reference, :reason,
                :unit_cost_cents, :idempotency_key, :metadata, :event_recorder, :clock

    def now = @occurred_at || clock.current

    def replayed_movement
      return nil if idempotency_key.nil?

      StockMovement.find_by(idempotency_key:)
    end

    # ------------------------------------------------------------------------
    # `.lock` agrega FOR UPDATE. Ojo: `StockItem.lock.find(id)` bloquea SOLO
    # esta fila. Postgres NO escala el lock a la tabla (no hay lock escalation
    # como en SQL Server), así que dos operaciones sobre productos distintos
    # corren 100% en paralelo.
    #
    # `find` (y no `find_by`) para que un id inexistente tire RecordNotFound,
    # que es un bug, no una regla de negocio.
    # ------------------------------------------------------------------------
    def lock_stock_item!
      StockItem.lock.find(@stock_item_id)
    end

    def validate!(item)
      new_on_hand = item.quantity_on_hand + quantity
      new_reserved = item.quantity_reserved + reserved_delta

      if new_on_hand.negative?
        fail!(:insufficient_stock,
              "Stock insuficiente: hay #{item.quantity_on_hand}, se pidieron #{quantity.abs}",
              available: item.quantity_available, requested: quantity.abs,
              product_id: item.product_id, warehouse_id: item.warehouse_id)
      end

      if new_reserved.negative?
        fail!(:invalid_reservation,
              "La reserva resultante sería negativa (#{new_reserved})")
      end

      # LA invariante del dominio: no podés comprometer más de lo que tenés.
      if new_reserved > new_on_hand
        fail!(:insufficient_available_stock,
              "Disponible insuficiente: quedarían #{new_on_hand} en mano con #{new_reserved} reservados",
              available: item.quantity_available, requested: quantity.abs)
      end

      fail!(:product_discarded, "El producto está dado de baja") if item.product.discarded?
    end

    def apply_to(item)
      item.quantity_on_hand += quantity
      item.quantity_reserved += reserved_delta
      item.last_movement_at = now
      item.save!
      # `reload` para leer `quantity_available`, que la calcula Postgres (columna
      # generada) y por lo tanto NO se actualiza sola en el objeto en memoria.
      item.reload
    end

    def write_ledger_entry(item)
      StockMovement.create!(
        stock_item: item,
        product_id: item.product_id,
        warehouse_id: item.warehouse_id,
        user:,
        kind:,
        quantity:,
        quantity_after: item.quantity_on_hand,
        unit_cost_cents:,
        currency: item.product.currency,
        reference:,
        idempotency_key:,
        reason:,
        metadata:,
        occurred_at: now
      )
    end

    def publish_event(item, movement)
      event_recorder.record(
        aggregate: item,
        event_type: "stock.#{kind}",
        occurred_at: now,
        payload: {
          stock_item_id: item.id,
          product_id: item.product_id,
          product_sku: item.product.sku,
          warehouse_id: item.warehouse_id,
          warehouse_code: item.warehouse.code,
          movement_id: movement.id,
          kind:,
          quantity:,
          quantity_on_hand: item.quantity_on_hand,
          quantity_reserved: item.quantity_reserved,
          quantity_available: item.quantity_available,
          below_reorder_point: item.below_reorder_point?
        },
        metadata:
      )
    end
  end
end

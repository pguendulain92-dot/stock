# frozen_string_literal: true

require "rails_helper"

# El ciclo de vida completo de una reserva, en un solo spec para que se lea
# como la especificación del flujo.
RSpec.describe "Ciclo de vida de una reserva" do
  let(:user) { create(:user, :operator) }
  let(:product) { create(:product) }
  let(:warehouse) { create(:warehouse) }
  let(:recorder) { Outbox::NullRecorder.new }
  let!(:item) { create(:stock_item, product:, warehouse:, quantity_on_hand: 100) }

  def reserve(quantity, **options)
    Stock::Reserve.call(product:, warehouse:, quantity:, user:, event_recorder: recorder, **options)
  end

  describe Stock::Reserve do
    it "baja el disponible SIN tocar el stock físico" do
      reserve(30)
      item.reload

      expect(item.quantity_on_hand).to eq(100)     # la mercadería sigue ahí
      expect(item.quantity_reserved).to eq(30)
      expect(item.quantity_available).to eq(70)    # pero ya no se puede vender
    end

    it "NO escribe en el ledger: no hubo movimiento físico" do
      expect { reserve(30) }.not_to change(StockMovement, :count)
    end

    it "rechaza reservar más de lo disponible" do
      reserve(80)
      result = reserve(30)   # quedan 20

      expect(result.error.code).to eq(:insufficient_available_stock)
      expect(result.error.details).to include(available: 20, requested: 30)
    end

    it "asigna un vencimiento por defecto" do
      expect(reserve(10).value.expires_at).to be_within(5.seconds).of(StockReservation::DEFAULT_TTL.from_now)
    end

    it "es idempotente por clave" do
      key = SecureRandom.uuid
      primera = reserve(10, idempotency_key: key)
      segunda = reserve(10, idempotency_key: key)

      expect(segunda.value.id).to eq(primera.value.id)
      expect(item.reload.quantity_reserved).to eq(10)
    end
  end

  describe Stock::CommitReservation do
    let(:reservation) { reserve(30).value }

    def commit = described_class.call(reservation:, user:, event_recorder: recorder)

    it "baja LAS DOS cantidades de forma atómica" do
      commit
      item.reload

      expect(item.quantity_on_hand).to eq(70)     # salió del depósito
      expect(item.quantity_reserved).to eq(0)     # ya no está comprometido
      expect(item.quantity_available).to eq(70)   # el disponible NO cambió
    end

    it "el disponible no se mueve durante el commit (ya se descontó al reservar)" do
      reservation   # forzamos la creación de la reserva (let es perezoso)
      disponible_antes = item.reload.quantity_available
      expect(disponible_antes).to eq(70)

      commit

      # Bajan on_hand y reserved a la vez, así que la resta da lo mismo.
      expect(item.reload.quantity_available).to eq(disponible_antes)
    end

    it "escribe el egreso en el ledger" do
      expect { commit }.to change(StockMovement, :count).by(1)
      expect(StockMovement.last.quantity).to eq(-30)
    end

    it "marca la reserva como committed" do
      commit
      expect(reservation.reload).to be_committed
      expect(reservation.committed_at).to be_present
    end

    it "es idempotente: confirmar dos veces no descuenta dos veces" do
      commit
      segundo = commit

      expect(segundo).to be_ok
      expect(item.reload.quantity_on_hand).to eq(70)
    end

    it "rechaza confirmar una reserva vencida" do
      reservation.update!(expires_at: 1.minute.ago)
      expect(commit.error.code).to eq(:reservation_expired)
    end

    it "rechaza confirmar una reserva ya liberada" do
      Stock::ReleaseReservation.call(reservation:, event_recorder: recorder)
      expect(commit.error.code).to eq(:reservation_not_active)
    end
  end

  describe Stock::ReleaseReservation do
    let(:reservation) { reserve(30).value }

    it "devuelve el stock al disponible" do
      described_class.call(reservation:, event_recorder: recorder)
      item.reload

      expect(item.quantity_reserved).to eq(0)
      expect(item.quantity_available).to eq(100)
      expect(item.quantity_on_hand).to eq(100)   # nunca se movió físicamente
    end

    it "es idempotente: liberar dos veces devuelve éxito, no un 4xx" do
      described_class.call(reservation:, event_recorder: recorder)
      segunda = described_class.call(reservation:, event_recorder: recorder)

      expect(segunda).to be_ok
      expect(item.reload.quantity_reserved).to eq(0)
    end
  end

  describe Stock::ExpireReservations do
    it "libera SÓLO las vencidas" do
      vencida = reserve(10).value
      viva = reserve(20).value
      vencida.update_column(:expires_at, 1.minute.ago)

      result = described_class.call(event_recorder: recorder)

      expect(result.value[:expired]).to eq(1)
      expect(vencida.reload).to be_expired
      expect(viva.reload).to be_held
      expect(item.reload.quantity_reserved).to eq(20)
    end

    it "usa una transacción POR RESERVA: un fallo aislado no arrastra al resto" do
      a = reserve(10).value
      b = reserve(20).value
      [ a, b ].each { |r| r.update_column(:expires_at, 1.minute.ago) }

      # Hacemos fallar sólo a la primera.
      allow(Stock::ReleaseReservation).to receive(:call).and_call_original
      allow(Stock::ReleaseReservation).to receive(:call)
        .with(hash_including(reservation: a)).and_return(Result.failure(:boom, "falló"))

      result = described_class.call(event_recorder: recorder)

      expect(result.value[:expired]).to eq(1)
      expect(result.value[:failed].size).to eq(1)
      expect(b.reload).to be_expired    # la segunda sí se procesó
    end
  end
end

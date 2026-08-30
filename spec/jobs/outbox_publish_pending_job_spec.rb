# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::PublishPendingJob, type: :job do
  let(:publisher) { Outbox::Publisher::NoopAdapter.new }

  before { allow(Outbox::Publisher).to receive(:build).and_return(publisher) }

  def crear_eventos(n) = create_list(:outbox_event, n)

  it "publica los pendientes y los marca" do
    crear_eventos(3)

    described_class.perform_now

    expect(publisher.published.size).to eq(3)
    expect(OutboxEvent.pending.count).to eq(0)
    expect(OutboxEvent.published.count).to eq(3)
  end

  it "no vuelve a publicar lo ya publicado" do
    crear_eventos(2)
    described_class.perform_now
    described_class.perform_now

    expect(publisher.published.size).to eq(2)
  end

  it "el mensaje lleva event_id para que el consumidor pueda deduplicar" do
    crear_eventos(1)
    described_class.perform_now

    mensaje = publisher.published.first
    expect(mensaje[:event_id]).to be_present
    expect(mensaje[:event_type]).to eq("stock.receipt")
    expect(mensaje[:aggregate]).to include(type: "StockItem")
  end

  describe "poison message" do
    it "un evento que falla NO frena a los demás" do
      malo = create(:outbox_event, event_type: "boom")
      crear_eventos(2)

      allow(publisher).to receive(:publish).and_call_original
      allow(publisher).to receive(:publish)
        .with(hash_including(event_type: "boom")).and_raise(StandardError, "el broker lo rechazó")

      described_class.perform_now

      expect(OutboxEvent.published.count).to eq(2)
      expect(malo.reload.published_at).to be_nil
      expect(malo.attempts).to eq(1)
      expect(malo.last_error).to include("el broker lo rechazó")
    end

    it "deja de intentar después de MAX_ATTEMPTS (no tapa la cola para siempre)" do
      agotado = create(:outbox_event, attempts: OutboxEvent::MAX_ATTEMPTS)

      described_class.perform_now

      expect(publisher.published).to be_empty
      expect(agotado.reload.published_at).to be_nil
      expect(OutboxEvent.stuck).to include(agotado)
    end
  end

  describe "backpressure" do
    it "se re-encola solo si llenó el lote (drena rápido después de un pico)" do
      crear_eventos(3)

      expect { described_class.perform_now(batch_size: 3) }
        .to have_enqueued_job(described_class)
    end

    it "NO se re-encola si el lote no estaba lleno" do
      crear_eventos(1)

      expect { described_class.perform_now(batch_size: 100) }
        .not_to have_enqueued_job(described_class)
    end
  end

  describe "claim_batch usa SKIP LOCKED" do
    it "genera FOR UPDATE SKIP LOCKED (lo que permite N workers en paralelo)" do
      expect(OutboxEvent.claim_batch.to_sql).to include("FOR UPDATE SKIP LOCKED")
    end
  end
end

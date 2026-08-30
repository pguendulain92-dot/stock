# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApiToken do
  let(:user) { create(:user, :manager) }

  describe ".issue!" do
    subject(:token) { described_class.issue!(user:, name: "integración", scopes: %w[stock:read]) }

    it "devuelve el token EN CLARO una única vez" do
      expect(token.plaintext).to start_with("stk_")
      # Al releerlo de la base, el plaintext ya no existe.
      expect(described_class.find(token.id).plaintext).to be_nil
    end

    it "guarda sólo el digest, nunca el token" do
      expect(token.token_digest).to eq(described_class.digest(token.plaintext))
      expect(token.token_digest).not_to include(token.plaintext)
    end

    it "genera 256 bits de entropía" do
      raw = token.plaintext.delete_prefix("stk_")
      # urlsafe_base64(32) -> 43 caracteres sin padding
      expect(raw.length).to be >= 43
    end

    it "dos tokens nunca colisionan" do
      otro = described_class.issue!(user:, name: "otro", scopes: [])
      expect(otro.plaintext).not_to eq(token.plaintext)
    end
  end

  describe ".authenticate" do
    let!(:token) { described_class.issue!(user:, name: "t", scopes: %w[stock:read]) }

    it "encuentra el token por su digest" do
      expect(described_class.authenticate(token.plaintext)).to eq(token)
    end

    it "devuelve nil con un token inventado" do
      expect(described_class.authenticate("stk_inventado")).to be_nil
    end

    it "devuelve nil si está revocado" do
      token.revoke!
      expect(described_class.authenticate(token.plaintext)).to be_nil
    end

    it "devuelve nil si venció" do
      token.update!(expires_at: 1.second.ago)
      expect(described_class.authenticate(token.plaintext)).to be_nil
    end

    it "no explota con nil ni con string vacío" do
      expect(described_class.authenticate(nil)).to be_nil
      expect(described_class.authenticate("")).to be_nil
    end
  end

  describe "#permits?" do
    it "respeta el scope pedido" do
      token = described_class.issue!(user:, name: "t", scopes: %w[stock:read])
      expect(token.permits?("stock:read")).to be(true)
      expect(token.permits?("stock:write")).to be(false)
    end

    it "el scope admin abre todo" do
      token = described_class.issue!(user:, name: "t", scopes: %w[admin])
      expect(token.permits?("cualquier:cosa")).to be(true)
    end
  end

  describe "#touch_usage!" do
    let!(:token) { described_class.issue!(user:, name: "t", scopes: []) }

    it "registra el uso" do
      expect { token.touch_usage! }.to change { token.reload.requests_count }.by(1)
    end

    it "THROTTLEA la escritura: no escribe dos veces en el mismo minuto" do
      token.touch_usage!
      expect { token.touch_usage! }.not_to change { token.reload.requests_count }
    end
  end

  describe "validación de scopes" do
    it "rechaza un scope inventado" do
      token = build(:api_token, user:, scopes: %w[stock:read inventado])
      expect(token).not_to be_valid
      expect(token.errors[:scopes].join).to include("inventado")
    end
  end
end

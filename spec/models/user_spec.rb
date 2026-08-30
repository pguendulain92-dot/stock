# frozen_string_literal: true

require "rails_helper"

RSpec.describe User do
  subject { build(:user) }

  describe "validaciones" do
    it { is_expected.to validate_presence_of(:email_address) }
    it { is_expected.to have_secure_password }
    it { is_expected.to validate_uniqueness_of(:email_address).case_insensitive }
  end

  describe "normalización" do
    it "baja a minúsculas y recorta el email" do
      user = create(:user, email_address: "  ANA@Stock.TEST  ")
      expect(user.email_address).to eq("ana@stock.test")
    end

    it "`normalizes` también aplica EN LAS BÚSQUEDAS (Rails 7.1+)" do
      user = create(:user, email_address: "ana@stock.test")
      # Antes de `normalizes`, esto devolvía nil y era un bug clásico de login.
      expect(described_class.find_by(email_address: "  ANA@STOCK.TEST ")).to eq(user)
    end

    it "citext hace que el índice único sea case-insensitive en la base" do
      create(:user, email_address: "ana@stock.test")
      expect { described_class.new(email_address: "ANA@STOCK.TEST", password: "x" * 12).save!(validate: false) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "roles" do
    it "usa strings, no enteros (los datos históricos no cambian de significado)" do
      expect(create(:user, :manager).read_attribute_before_type_cast(:role)).to eq("manager")
    end

    it "rechaza un rol desconocido con un error de validación, no una excepción" do
      user = build(:user)
      user.role = "emperador"
      expect(user).not_to be_valid
      expect(user.errors[:role]).to be_present
    end

    it "el CHECK de la base también lo rechaza" do
      user = create(:user)
      expect { user.update_column(:role, "emperador") }
        .to raise_error(ActiveRecord::StatementInvalid, /users_role_check/)
    end

    describe "#at_least?" do
      it "implementa la jerarquía viewer < operator < manager < admin" do
        expect(build(:user, :admin).at_least?("manager")).to be(true)
        expect(build(:user, :operator).at_least?("manager")).to be(false)
        expect(build(:user, :operator).at_least?("operator")).to be(true)
        expect(build(:user, :viewer).at_least?("viewer")).to be(true)
      end
    end
  end

  describe ".authenticate_by" do
    let!(:user) { create(:user, email_address: "ana@stock.test", password: "password123") }

    it "autentica con credenciales correctas" do
      expect(described_class.authenticate_by(email_address: "ana@stock.test", password: "password123"))
        .to eq(user)
    end

    it "devuelve nil con la contraseña mal" do
      expect(described_class.authenticate_by(email_address: "ana@stock.test", password: "mal")).to be_nil
    end

    it "devuelve nil con un email inexistente" do
      expect(described_class.authenticate_by(email_address: "nadie@stock.test", password: "x")).to be_nil
    end
  end
end

# frozen_string_literal: true

require "rails_helper"

# ==============================================================================
# Los tests de policy son los más baratos y de los más valiosos: son puro Ruby,
# sin base ni HTTP, y cubren la superficie de seguridad de la app.
#
# El patrón de MATRIZ (rol x acción) documenta la política de acceso mejor que
# cualquier wiki, y falla apenas alguien afloja un permiso sin querer.
# ==============================================================================
RSpec.describe "Políticas de autorización" do
  let(:admin)    { build_stubbed(:user, :admin) }
  let(:manager)  { build_stubbed(:user, :manager) }
  let(:operator) { build_stubbed(:user, :operator) }
  let(:viewer)   { build_stubbed(:user, :viewer) }
  let(:inactivo) { build_stubbed(:user, :admin, active: false) }

  describe StockItemPolicy do
    let(:item) { build_stubbed(:stock_item) }

    matriz = {
      show?:    %i[admin manager operator viewer],
      receive?: %i[admin manager operator],
      issue?:   %i[admin manager operator],
      adjust?:  %i[admin manager],            # ajustar inventario toca la contabilidad
      reserve?: %i[admin manager operator]
    }

    matriz.each do |accion, roles_permitidos|
      %i[admin manager operator viewer].each do |rol|
        permitido = roles_permitidos.include?(rol)

        it "#{rol} #{permitido ? 'PUEDE' : 'NO puede'} #{accion}" do
          policy = described_class.new(send(rol), item)
          expect(policy.public_send(accion)).to eq(permitido)
        end
      end
    end

    it "un usuario INACTIVO no puede nada, aunque sea admin" do
      policy = described_class.new(inactivo, item)
      expect(policy.show?).to be_falsey
      expect(policy.adjust?).to be_falsey
    end

    it "sin usuario (anónimo) no puede nada: deny by default" do
      policy = described_class.new(nil, item)
      expect(policy.show?).to be_falsey
      expect(policy.receive?).to be_falsey
    end
  end

  describe UserPolicy do
    let(:otro) { build_stubbed(:user, :operator) }

    it "sólo un admin lista usuarios" do
      expect(described_class.new(admin, otro).index?).to be(true)
      expect(described_class.new(manager, otro).index?).to be_falsey
    end

    it "cualquiera puede verse a sí mismo" do
      expect(described_class.new(operator, operator).show?).to be(true)
    end

    it "nadie puede ver a otro salvo un admin" do
      expect(described_class.new(operator, otro).show?).to be_falsey
    end

    # ESCALADA DE PRIVILEGIOS: sin esta regla, un usuario se auto-promueve
    # editando su propio perfil. Es uno de los bugs de autorización más comunes.
    it "nadie puede cambiarse el rol a sí mismo, ni siquiera un admin" do
      expect(described_class.new(admin, admin).change_role?).to be(false)
      expect(described_class.new(admin, otro).change_role?).to be(true)
    end

    it "nadie se borra a sí mismo" do
      expect(described_class.new(admin, admin).destroy?).to be(false)
    end
  end

  describe "Scopes (el filtrado de las COLECCIONES)" do
    it "UserPolicy::Scope: un no-admin sólo se ve a sí mismo" do
      yo = create(:user, :operator)
      create(:user, :operator)

      expect(UserPolicy::Scope.new(yo, User).resolve).to contain_exactly(yo)
      expect(UserPolicy::Scope.new(create(:user, :admin), User).resolve.count).to eq(3)
    end

    it "ProductPolicy::Scope: un viewer no ve productos dados de baja" do
      create(:product)
      create(:product, :discarded)

      expect(ProductPolicy::Scope.new(viewer, Product).resolve.count).to eq(1)
      expect(ProductPolicy::Scope.new(operator, Product).resolve.count).to eq(2)
    end

    it "el Scope base devuelve NADA: si te olvidás de implementarlo, no filtra de menos" do
      expect(ApplicationPolicy::Scope.new(admin, Product).resolve).to be_empty
    end
  end

  describe StockTransferPolicy do
    # ─────────────────────────────────────────────────────────────────────────
    # La policy responde SÓLO por el permiso, no por el estado. Ver la nota en
    # app/policies/purchase_order_policy.rb: mezclarlos hace que "enviar dos
    # veces" devuelva 403 (nunca vas a poder) en vez de 422 (ya está enviada).
    # ─────────────────────────────────────────────────────────────────────────
    it "el permiso NO depende del estado del recurso" do
      borrador = build_stubbed(:stock_transfer, status: "draft")
      recibida = build_stubbed(:stock_transfer, status: "received")

      expect(described_class.new(operator, borrador).dispatch?).to be(true)
      expect(described_class.new(operator, recibida).dispatch?).to be(true)
    end

    it "cancelar es de manager para arriba" do
      transfer = build_stubbed(:stock_transfer)
      expect(described_class.new(operator, transfer).cancel?).to be_falsey
      expect(described_class.new(manager, transfer).cancel?).to be(true)
    end

    it "el ESTADO lo valida el modelo, no la policy" do
      recibida = build_stubbed(:stock_transfer, status: "received")
      expect(recibida.can_transition_to?("in_transit")).to be(false)
    end
  end
end

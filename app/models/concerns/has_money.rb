# frozen_string_literal: true

# ==============================================================================
# HasMoney — macro de clase que expone una columna `*_cents` como Value Object.
#
# Esto es METAPROGRAMACIÓN, que en Ruby es cotidiana y en Java requeriría un
# annotation processor o generación de bytecode. `define_method` crea métodos en
# tiempo de carga de la clase; el costo es cero en runtime.
#
#   class Product
#     include HasMoney
#     has_money :cost      # -> #cost y #cost= trabajando con ValueObjects::Money
#   end
#
#   product.cost                    # => #<Money cents=1500 currency="USD">
#   product.cost = Money.from_amount("19.99", "USD")
#   product.cost_cents              # => 1999   (la columna cruda sigue ahí)
#
# El objetivo SOLID: la lógica de dinero vive en UN lugar (Money), no repartida
# en cada modelo que tenga un precio.
# ==============================================================================
module HasMoney
  extend ActiveSupport::Concern

  class_methods do
    def has_money(name, currency_column: :currency)
      cents_column = :"#{name}_cents"

      define_method(name) do
        ValueObjects::Money.new(
          cents: public_send(cents_column) || 0,
          currency: public_send(currency_column) || "USD"
        )
      end

      define_method(:"#{name}=") do |money|
        case money
        in ValueObjects::Money => m
          public_send(:"#{cents_column}=", m.cents)
          public_send(:"#{currency_column}=", m.currency)
        in Integer => cents
          public_send(:"#{cents_column}=", cents)
        in nil
          public_send(:"#{cents_column}=", 0)
        else
          raise ArgumentError, "#{name}= espera Money o Integer (centavos), recibió #{money.class}"
        end
      end
    end
  end
end

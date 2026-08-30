# frozen_string_literal: true

class ProductSerializer < ApplicationSerializer
  def as_json
    {
      id: object.id,
      sku: object.sku,
      name: object.name,
      description: object.description,
      barcode: object.barcode,
      unit: object.unit,
      active: object.active,
      discarded: object.discarded?,
      cost: object.cost.as_json,
      price: object.price.as_json,
      # `object.category` puede disparar un N+1 si el caller no hizo includes.
      # Por eso los query objects de este proyecto SIEMPRE hacen includes(:category),
      # y hay un test que falla si aparece un N+1 (ver spec/requests + Bullet).
      category: object.category && { id: object.category.id, name: object.category.name,
                                     slug: object.category.slug },
      # `availability` se pasa POR PARÁMETRO, precalculada con un GROUP BY.
      # No la calculamos acá adentro: eso sería el N+1 en persona.
      availability: options[:availability],
      created_at: iso(object.created_at),
      updated_at: iso(object.updated_at)
    }.compact
  end
end

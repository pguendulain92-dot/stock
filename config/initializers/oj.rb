# frozen_string_literal: true

# ==============================================================================
# Oj — serializador/parser JSON escrito en C.
#
# INSTALAR LA GEMA NO HACE NADA. Hay que engancharla, y esto es un error muy
# común: agregás `gem "oj"`, ves que el Gemfile.lock la tiene, asumís que la
# app va más rápido... y seguís usando el JSON de la stdlib. Comprobalo:
#
#   ActiveSupport::JSON::Encoding.json_encoder
#   # sin esto:  ActiveSupport::JSON::Encoding::JSONGemEncoder
#   # con esto:  Oj::Rails::Encoder
#
# `Oj.optimize_rails` reemplaza el encoder de ActiveSupport y agrega
# optimizaciones para los tipos de Rails (Time, BigDecimal, ActiveRecord).
#
# `mode: :rails` es OBLIGATORIO si querés compatibilidad de salida con Rails.
# Los otros modos (:compat, :object, :strict) serializan distinto —sobre todo
# fechas y BigDecimal— y te cambian el contrato de la API en silencio.
#
# ⚠️ Medí antes de asumir la ganancia. En este repo, con payloads chicos, la
# diferencia es despreciable y en `mode: :rails` puede ser incluso más lento
# que el encoder por defecto: Oj gana con payloads grandes y con muchos
# objetos anidados. Es el ejemplo perfecto de optimización de cargo cult.
# ==============================================================================
require "oj"

Oj.default_options = { mode: :rails }
Oj.optimize_rails

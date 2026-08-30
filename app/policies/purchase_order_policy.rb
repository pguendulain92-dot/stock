# frozen_string_literal: true

# ==============================================================================
# ⚠️ SEPARACIÓN IMPORTANTE: PERMISO vs ESTADO.
#
# Es tentador escribir `def submit? = manager? && record.draft?`. Pundit lo
# permite y verás ese estilo en muchos proyectos. Pero mezcla dos preguntas
# distintas y el resultado se le nota al cliente de la API:
#
#   * "¿este usuario tiene DERECHO a hacer esto?"      -> 403 Forbidden
#   * "¿el recurso está en un ESTADO que lo permita?"  -> 422 Unprocessable
#
# Si metés el estado en la policy, enviar dos veces la misma orden devuelve
# 403. Y un 403 le dice al cliente "nunca vas a poder", cuando la realidad es
# "ya está enviada". El cliente no puede distinguir un problema de permisos de
# uno de flujo, y termina mostrándole al usuario el mensaje equivocado.
#
# Regla de este proyecto: la POLICY mira sólo al usuario y su rol. El ESTADO lo
# valida el controller (o el service) y devuelve 422 con el código
# `invalid_transition`. La máquina de estados vive en el modelo
# (PurchaseOrder::TRANSITIONS), que es su lugar natural.
# ==============================================================================
class PurchaseOrderPolicy < ApplicationPolicy
  def create?  = operator?
  def submit?  = manager?
  def receive? = operator?
  def cancel?  = manager?
  def destroy? = manager?

  class Scope < ApplicationPolicy::Scope
    def resolve = user&.active? ? scope.all : scope.none
  end
end

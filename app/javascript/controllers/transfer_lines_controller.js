import { Controller } from "@hotwired/stimulus"

// Controller de Stimulus: agrega filas al formulario de transferencia.
//
// Stimulus NO es un framework de vistas. No hay virtual DOM ni estado
// centralizado. Es un "sprinkle" de comportamiento sobre HTML que ya existe:
// el servidor manda el HTML y Stimulus le engancha eventos. Filosofía opuesta a
// React/Angular, y es una decisión de arquitectura defendible: en una app
// CRUD-pesada como esta, el 95% de la interacción la resuelve el servidor y
// mantener un SPA sería duplicar el modelo de dominio en JavaScript.
//
// LA CONVENCIÓN ES LA FEATURE: el archivo transfer_lines_controller.js se
// conecta SOLO a cualquier elemento con data-controller="transfer-lines".
// No hay que registrarlo a mano; el importmap + el loader lo descubren.
//
//   static targets = ["container"]   -> this.containerTarget
//                                       (busca data-transfer-lines-target="container")
//   data-action="transfer-lines#add" -> llama a this.add(event)
export default class extends Controller {
  static targets = ["container"]

  add() {
    const first = this.containerTarget.firstElementChild
    if (!first) return

    const clone = first.cloneNode(true)
    // Reseteamos la cantidad del clon: copiar el valor anterior confunde.
    const quantity = clone.querySelector("input[type=number]")
    if (quantity) quantity.value = 1
    this.containerTarget.appendChild(clone)
  }
}

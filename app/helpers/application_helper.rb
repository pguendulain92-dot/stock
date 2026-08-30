# frozen_string_literal: true

module ApplicationHelper
  include Pagy::Frontend

  # Clases de Tailwind por tipo de movimiento. Mantener el mapeo en un helper
  # (y no repartido en las vistas) hace que agregar un tipo nuevo sea un
  # cambio en un solo lugar.
  MOVEMENT_STYLES = {
    "receipt" => "bg-emerald-100 text-emerald-800",
    "transfer_in" => "bg-sky-100 text-sky-800",
    "return" => "bg-teal-100 text-teal-800",
    "issue" => "bg-rose-100 text-rose-800",
    "transfer_out" => "bg-amber-100 text-amber-800",
    "scrap" => "bg-red-100 text-red-800",
    "adjustment" => "bg-violet-100 text-violet-800",
    "count_correction" => "bg-violet-100 text-violet-800"
  }.freeze

  STATUS_STYLES = {
    "draft" => "bg-slate-100 text-slate-700",
    "in_transit" => "bg-amber-100 text-amber-800",
    "received" => "bg-emerald-100 text-emerald-800",
    "cancelled" => "bg-slate-200 text-slate-500",
    "held" => "bg-sky-100 text-sky-800",
    "committed" => "bg-emerald-100 text-emerald-800",
    "released" => "bg-slate-100 text-slate-600",
    "expired" => "bg-rose-100 text-rose-700"
  }.freeze

  def movement_badge(kind)
    tag.span(kind.humanize,
             class: "inline-flex rounded-full px-2 py-0.5 text-xs font-medium #{MOVEMENT_STYLES.fetch(kind, 'bg-slate-100 text-slate-700')}")
  end

  def status_badge(status)
    tag.span(status.to_s.humanize,
             class: "inline-flex rounded-full px-2 py-0.5 text-xs font-medium #{STATUS_STYLES.fetch(status.to_s, 'bg-slate-100 text-slate-700')}")
  end

  def signed_quantity(value)
    css = value.negative? ? "text-rose-600" : "text-emerald-600"
    tag.span(format("%+d", value), class: "font-mono font-semibold #{css}")
  end

  def money(money_object) = money_object.to_s

  def stock_level_class(item)
    return "text-rose-600 font-semibold" if item.quantity_available <= 0
    return "text-amber-600 font-semibold" if item.below_reorder_point?

    "text-slate-900"
  end
end

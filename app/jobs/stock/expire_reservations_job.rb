# frozen_string_literal: true

module Stock
  # Corre cada minuto (config/recurring.yml). Libera las reservas vencidas.
  # Sin este job, las reservas huérfanas te comen el stock disponible para
  # siempre. Es el job más importante del sistema y el que más se olvida.
  class ExpireReservationsJob < ApplicationJob
    queue_as :maintenance

    def perform(limit: 5_000)
      result = ExpireReservations.call(limit:)
      Rails.logger.info(event: "reservations.expired", **result.value)
      result.value
    end
  end
end

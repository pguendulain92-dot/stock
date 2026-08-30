# frozen_string_literal: true

# ==============================================================================
# EL ADAPTER DE COLAS ES INTERCAMBIABLE — y ese es todo el punto de Active Job.
#
# Cambiás UNA variable de entorno y los MISMOS jobs corren sobre otro backend.
# Esto es Dependency Inversion a nivel framework: tu código depende de la
# abstracción `ActiveJob::Base`, no de Sidekiq ni de Solid Queue.
#
#   QUEUE_ADAPTER=solid_queue bin/rails s   # Postgres, sin Redis
#   QUEUE_ADAPTER=sidekiq     bin/rails s   # Redis
#   QUEUE_ADAPTER=async       bin/rails s   # in-process (SÓLO desarrollo)
#   QUEUE_ADAPTER=inline      bin/rails s   # ejecuta ya, sin cola (debug)
#
# ⚠️ `async` es el default de desarrollo de Rails y es una TRAMPA: mantiene los
# jobs en un thread pool EN MEMORIA. Si el proceso se reinicia, se pierden
# TODOS los jobs pendientes, sin aviso. Está bien para probar; en producción es
# pérdida de datos garantizada.
#
# Comparación completa en docs/07.
# ==============================================================================
Rails.application.configure do
  # En TEST el adapter tiene que ser :test. Ese adapter NO ejecuta nada: sólo
  # acumula los jobs encolados en un array que podés inspeccionar con los
  # matchers `have_enqueued_job` / `perform_enqueued_jobs`. Si dejaras
  # solid_queue en test, cada spec escribiría filas en la base de jobs y los
  # tests se volverían lentos y acoplados entre sí.
  default_adapter = Rails.env.test? ? "test" : "solid_queue"
  adapter = ENV.fetch("QUEUE_ADAPTER", default_adapter)

  config.active_job.queue_adapter = adapter.to_sym

  # Prefijo de cola por entorno: evita que un worker de staging tome jobs de
  # producción si comparten Redis por accidente. Pasa más seguido de lo que
  # parece y es un desastre cuando pasa.
  config.active_job.queue_name_prefix = Rails.env.production? ? nil : Rails.env

  config.solid_queue.connects_to = { database: { writing: :queue } } if adapter == "solid_queue"

  # `default_queue_name`: si un job no declara `queue_as`, cae acá.
  config.active_job.default_queue_name = "default"
end

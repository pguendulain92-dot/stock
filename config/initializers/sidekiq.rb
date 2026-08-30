# frozen_string_literal: true

# ==============================================================================
# Sidekiq — el adapter alternativo, sobre Redis.
#
# Sólo se configura si QUEUE_ADAPTER=sidekiq. La gema está en el Gemfile a
# propósito, para poder comparar los dos backends con el MISMO código de jobs.
#
# DIFERENCIAS QUE HAY QUE SABER (Sidekiq vs Solid Queue):
#
# | Aspecto        | Sidekiq (Redis)              | Solid Queue (Postgres)        |
# |----------------|------------------------------|-------------------------------|
# | Latencia       | ~1 ms (BRPOP, bloqueante)    | 100 ms - 1 s (polling)        |
# | Throughput     | decenas de miles/s           | miles/s                       |
# | Durabilidad    | depende de la config de Redis| ACID, igual que tus datos     |
# | Transaccional  | ❌ el enqueue no está en tu tx| ✅ mismo COMMIT que el negocio |
# | Infra          | Redis aparte                 | ninguna extra                 |
# | Dashboard      | Sidekiq Web                  | Mission Control               |
#
# EL PUNTO "TRANSACCIONAL" ES EL MÁS IMPORTANTE Y EL MENOS CONOCIDO:
#
#   ActiveRecord::Base.transaction do
#     order.update!(status: "paid")
#     SendReceiptJob.perform_later(order.id)   # ⚠️ con Sidekiq
#   end
#
# Con Sidekiq, el job se encola en Redis INMEDIATAMENTE. Si la transacción hace
# rollback después, el job ya salió y va a procesar una orden que no existe (o
# peor: que quedó en otro estado). Y al revés: el worker puede levantar el job
# ANTES de que Postgres commitee y no encontrar la fila.
#
# Rails 7.2+ trae `enqueue_after_transaction_commit` justamente para esto.
# Con Solid Queue el problema no existe: el INSERT del job va en TU transacción.
# ==============================================================================
if ENV["QUEUE_ADAPTER"] == "sidekiq"
  require "sidekiq"

  redis_config = {
    url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"),
    # El pool de Redis del lado del CLIENTE (la app web) tiene que alcanzar para
    # los threads de Puma. Si es menor, los threads se pelean por conexiones.
    network_timeout: 2,
    pool_timeout: 2
  }

  Sidekiq.configure_server do |config|
    config.redis = redis_config

    # DEAD LETTER QUEUE: después de agotar los reintentos, Sidekiq manda el job
    # al "Dead set" en vez de tirarlo. Ahí lo podés inspeccionar y reintentar a
    # mano. Una cola sin DLQ pierde trabajo en silencio.
    config.death_handlers << lambda do |job, exception|
      Rails.logger.error(event: "job.dead", job: job["class"], jid: job["jid"],
                         error: exception.message, args: job["args"])
    end
  end

  Sidekiq.configure_client { |config| config.redis = redis_config }
end

# ------------------------------------------------------------------------------
# ENCOLAR DESPUÉS DEL COMMIT (Rails 7.2+).
#
# Con esto, `perform_later` dentro de una transacción NO encola hasta que el
# COMMIT sea exitoso. Resuelve el problema descrito arriba para CUALQUIER
# adapter, y debería estar activado siempre.
#
# Ojo: NO reemplaza al patrón outbox. Si el proceso muere entre el COMMIT y el
# enqueue (una ventana de microsegundos, pero existe), el job se pierde igual y
# nadie se entera. Para eventos que NO se pueden perder, outbox. Para "mandale
# un mail al usuario", esto alcanza. Saber dónde está esa línea es la respuesta
# madura a "¿cuándo usarías un outbox?".
# ------------------------------------------------------------------------------
Rails.application.config.active_job.enqueue_after_transaction_commit = :always

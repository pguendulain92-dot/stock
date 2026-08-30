# frozen_string_literal: true

# ==============================================================================
# ApplicationJob — base de todos los jobs.
#
# ACTIVE JOB ES UNA FACHADA (una SPI), no una implementación. Vos escribís el
# job una vez y elegís el "adapter" por configuración: Solid Queue, Sidekiq,
# Delayed Job, SQS... Es exactamente el rol de JMS en Java: la API es estándar,
# el broker es intercambiable.
#
# EL PRECIO DE LA ABSTRACCIÓN (y hay que saberlo): Active Job expone el mínimo
# común denominador. Cosas específicas de Sidekiq (batches, unique jobs,
# rate limiting por cola de Sidekiq Enterprise) NO están en Active Job. Si las
# necesitás, tenés que heredar de `Sidekiq::Job` directamente y perder la
# portabilidad. Es un trade-off consciente, no un defecto.
#
# ─── LA REGLA MÁS IMPORTANTE DE LOS JOBS ──────────────────────────────────────
#
# PASÁ IDs, NO OBJETOS.
#
#   MiJob.perform_later(product)        # ❌
#   MiJob.perform_later(product.id)     # ✅
#
# ¿Por qué? Active Job serializa los argumentos (GlobalID para los modelos) y el
# job puede ejecutarse minutos u horas después. Si serializás el objeto:
#   * El estado que ves en el worker puede ser VIEJO (alguien lo modificó).
#   * Si el registro se borró, el job explota con RecordNotFound al deserializar,
#     y esa excepción ocurre ANTES de tu código, así que no la podés manejar.
#   * El payload es más grande (más red, más base).
# Con el id, releés el estado ACTUAL adentro del job y decidís qué hacer si no
# existe. En Java tendrías el mismo problema mandando entidades JPA por JMS.
#
# ─── LA SEGUNDA REGLA ─────────────────────────────────────────────────────────
#
# TODO JOB DEBE SER IDEMPOTENTE. Las colas garantizan AT-LEAST-ONCE, nunca
# exactly-once. Un worker puede morir después de hacer el trabajo y antes de
# marcar el job como completado => se reintenta => se ejecuta dos veces.
# Si tu job manda un mail o descuenta stock, tenés que poder detectarlo.
# ==============================================================================
class ApplicationJob < ActiveJob::Base
  # ┌──────────────────────────────────────────────────────────────────────────┐
  # │ ENCOLAR DESPUÉS DEL COMMIT — y por qué acá y no en un initializer.       │
  # │                                                                          │
  # │ El problema: `perform_later` dentro de una transacción encola el job     │
  # │ INMEDIATAMENTE. Si después la transacción hace rollback, el job igual    │
  # │ se ejecuta y procesa un registro que no existe (o que quedó en otro      │
  # │ estado). Y al revés: el worker puede tomar el job ANTES de que el COMMIT │
  # │ termine y no encontrar la fila.                                          │
  # │                                                                          │
  # │ ⚠️ TRAMPA QUE TUVIMOS VIVA EN ESTE REPO: escribir                        │
  # │     config.active_job.enqueue_after_transaction_commit = :always         │
  # │ en un initializer es un NO-OP en Rails 8.1. El railtie de Active Job     │
  # │ excluye esa clave a propósito de la configuración global ("This config   │
  # │ can't be applied globally") y además el valor :always se removió.        │
  # │ El resultado era el peor posible: parecía configurado y no lo estaba.    │
  # │ Verificalo con:  ActiveJob::Base.enqueue_after_transaction_commit        │
  # │                                                                          │
  # │ La forma correcta es POR CLASE DE JOB, como acá abajo.                   │
  # │                                                                          │
  # │ Y ojo: esto NO reemplaza al outbox. Si el proceso muere entre el COMMIT  │
  # │ y el enqueue, el job se pierde igual y nadie se entera. Para eventos que │
  # │ no se pueden perder, outbox (ver app/services/outbox/). Para "mandale un │
  # │ mail al usuario", esto alcanza.                                          │
  # └──────────────────────────────────────────────────────────────────────────┘
  self.enqueue_after_transaction_commit = true

  # --- Reintentos -------------------------------------------------------------
  #
  # `wait: :polynomially_longer` (Rails 7.1+) hace backoff POLINÓMICO, no
  # exponencial: la fórmula es `executions ** 4 + jitter + 2`. Rails renombró
  # la opción justamente por eso (antes se llamaba `:exponentially_longer` y
  # el nombre mentía). Los reintentos caen a los ~3s, ~18s, ~83s, ~258s...
  # En vez de martillar un servicio caído cada 5 segundos, le das tiempo a
  # recuperarse.
  #
  # En producción real querés además JITTER (ruido aleatorio): si 1000 jobs
  # fallan al mismo tiempo por una caída, con backoff determinístico los 1000
  # reintentan EXACTAMENTE en el mismo instante y vuelven a tumbar el servicio
  # apenas se levanta. Es el "thundering herd". Rails aplica un jitter del 15%
  # por defecto (`ActiveJob::Base.retry_jitter`).
  retry_on ActiveRecord::Deadlocked, wait: :polynomially_longer, attempts: 5
  retry_on ActiveRecord::LockWaitTimeout, wait: :polynomially_longer, attempts: 5
  retry_on ActiveRecord::ConnectionNotEstablished, wait: :polynomially_longer, attempts: 5

  # --- Descartes --------------------------------------------------------------
  #
  # `discard_on` es para errores que NO se arreglan reintentando. Reintentar un
  # RecordNotFound 25 veces es puro desperdicio: el registro no va a reaparecer.
  # Distinguir "error transitorio" (retry) de "error permanente" (discard) es
  # lo que hace que una cola sea sana. Si retryás todo, la cola se tapa con
  # basura y los jobs buenos no entran.
  discard_on ActiveJob::DeserializationError do |job, error|
    Rails.logger.warn(event: "job.discarded", job: job.class.name,
                      reason: "registro inexistente", error: error.message)
  end

  around_perform do |job, block|
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Rails.logger.info(event: "job.start", job: job.class.name, jid: job.job_id, queue: job.queue_name)
    block.call
    Rails.logger.info(event: "job.finish", job: job.class.name, jid: job.job_id,
                      duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1))
  ensure
    # Los jobs también corren en threads reutilizados: si no limpiamos `Current`,
    # el job siguiente hereda el contexto del anterior. Rails ya lo hace por
    # nosotros vía el executor, pero dejarlo explícito documenta la intención.
    Current.reset
  end
end

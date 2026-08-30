# frozen_string_literal: true

# ==============================================================================
# Solid Queue — configuración que NO está en config/queue.yml.
#
# `shutdown_timeout` es el parámetro que más importa y el que nadie mira.
#
# QUÉ PASA EN UN DEPLOY: el orquestador manda SIGTERM al worker. Solid Queue
# deja de tomar jobs nuevos y espera a que terminen los que están corriendo.
# Si pasan `shutdown_timeout` segundos y todavía queda alguno, lo MATA.
#
# El default son 5 segundos. Si tenés jobs que tardan más que eso —y casi
# siempre los tenés: un import, un reporte, un webhook lento— cada deploy los
# corta a la mitad. El job queda marcado como "claimed" por un proceso que ya
# no existe y hay que esperar a que el supervisor lo libere.
#
# Por eso los jobs tienen que ser IDEMPOTENTES y CORTOS: no porque quede lindo,
# sino porque el deploy los va a interrumpir tarde o temprano.
#
# El número tiene que ser MENOR que el grace period de tu orquestador (en
# Kubernetes, terminationGracePeriodSeconds; en Kamal, el drain timeout del
# proxy). Si es mayor, el orquestador manda SIGKILL antes de que Solid Queue
# termine su apagado ordenado y perdés la ventaja de configurarlo.
# ==============================================================================
Rails.application.configure do
  config.solid_queue.shutdown_timeout = ENV.fetch("SOLID_QUEUE_SHUTDOWN_TIMEOUT", 25).to_i.seconds

  # Registrar en el log cada vez que un job falla definitivamente, además de
  # dejarlo en solid_queue_failed_executions. Sin esto, un job que agota los
  # reintentos desaparece de la vista salvo que alguien mire el dashboard.
  config.solid_queue.silence_polling = true   # el polling ensucia el log de SQL
end

# frozen_string_literal: true

module Outbox
  # ============================================================================
  # Publisher — la salida de los eventos hacia el mundo.
  #
  # Definimos una INTERFAZ (`publish(message)`) y varios adapters. El job de
  # publicación no conoce ninguno en concreto: eso es Dependency Inversion, y
  # es lo que permite testear el flujo entero sin un broker levantado.
  #
  # En Ruby no declaramos una `interface` como en Java: alcanza con que todos
  # respondan al mismo método (DUCK TYPING). La "interfaz" es un contrato
  # documentado + tests compartidos. Menos ceremonia, misma sustancia — pero
  # también menos ayuda del compilador, así que los tests son OBLIGATORIOS.
  # ============================================================================
  class Publisher
    ADAPTERS = {
      "log" => -> { LogAdapter.new },
      "noop" => -> { NoopAdapter.new },
      "webhook" => -> { WebhookAdapter.new(url: ENV.fetch("OUTBOX_WEBHOOK_URL")) }
      # "kafka"    => -> { KafkaAdapter.new(...) }      # ruby-kafka / rdkafka
      # "rabbitmq" => -> { RabbitAdapter.new(...) }     # bunny
      # "sns"      => -> { SnsAdapter.new(...) }        # aws-sdk-sns
    }.freeze

    def self.build(name = ENV.fetch("OUTBOX_ADAPTER", "log"))
      ADAPTERS.fetch(name) { raise ArgumentError, "Adapter de outbox desconocido: #{name}" }.call
    end

    # Adapter por defecto: escribe el evento al log estructurado. Suena a poco,
    # pero con un colector de logs (Datadog, Loki) ya tenés un stream de eventos
    # consultable, y es SUFICIENTE hasta que realmente necesites un broker.
    # "Empezá con lo simple" es una respuesta perfectamente válida en una
    # entrevista de arquitectura, siempre que sepas cuándo dejar de serlo.
    class LogAdapter
      def publish(message)
        Rails.logger.info(event: "domain_event", **message)
      end
    end

    class NoopAdapter
      attr_reader :published

      def initialize = @published = []
      def publish(message) = @published << message
    end

    # Webhook HTTP con FIRMA HMAC, estilo Stripe/GitHub.
    # La firma permite al receptor verificar que el evento vino de nosotros y no
    # fue modificado. Sin firma, cualquiera que conozca la URL puede inyectar
    # eventos falsos ("se recibieron 10.000 unidades").
    class WebhookAdapter
      def initialize(url:, secret: ENV["OUTBOX_WEBHOOK_SECRET"], timeout: 5)
        @uri = URI.parse(url)
        @secret = secret
        @timeout = timeout
      end

      def publish(message)
        body = message.to_json
        timestamp = Time.current.to_i

        request = Net::HTTP::Post.new(@uri)
        request["Content-Type"] = "application/json"
        request["X-Stock-Event"] = message[:event_type].to_s
        request["X-Stock-Timestamp"] = timestamp.to_s
        # El timestamp entra en la firma para evitar REPLAY ATTACKS: sin él, un
        # atacante que capture un webhook válido puede reenviarlo mil veces.
        request["X-Stock-Signature"] = sign("#{timestamp}.#{body}") if @secret
        request.body = body

        response = Net::HTTP.start(@uri.hostname, @uri.port,
                                   use_ssl: @uri.scheme == "https",
                                   open_timeout: @timeout, read_timeout: @timeout) do |http|
          http.request(request)
        end

        return if response.is_a?(Net::HTTPSuccess)

        raise DeliveryError, "El webhook respondió #{response.code}"
      end

      # `secure_compare` del lado del receptor, no acá. Acá sólo generamos.
      def sign(payload) = OpenSSL::HMAC.hexdigest("SHA256", @secret, payload)

      class DeliveryError < StandardError; end
    end
  end
end

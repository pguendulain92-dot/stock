# frozen_string_literal: true

# ==============================================================================
# CAPA 1 DE RATE LIMITING: Rack::Attack (middleware Rack, "en el borde").
#
# ¿QUÉ ES UN MIDDLEWARE RACK? Rack es la interfaz mínima entre servidor web y
# app Ruby: un objeto que responde `call(env)` y devuelve [status, headers, body].
# Los middlewares se apilan como capas de cebolla; cada uno puede cortar la
# cadena y responder sin llamar al siguiente. Es EXACTAMENTE el javax.servlet.Filter
# / la FilterChain de Spring Security.
#
# ¿POR QUÉ ACÁ Y NO EN EL CONTROLLER?
# Porque este middleware corre ANTES de que Rails instancie el controller, cargue
# la sesión, toque la base o corra un `before_action`. Una request bloqueada acá
# consume ~0.1 ms. Si la bloquearas en el controller, ya pagaste el routing, la
# deserialización, la autenticación y probablemente 2 queries. Bajo un ataque,
# esa diferencia es la que decide si el sitio se cae o no.
#
# ARQUITECTURA REAL (importante para la entrevista):
# En producción, lo IDEAL es limitar aún más afuera: Cloudflare/ALB/nginx.
# Rack::Attack es la segunda línea, no la primera; corre en tu proceso Ruby y por
# lo tanto ya te está costando un worker. Se usa para reglas que dependen de
# lógica de la app (por token, por tenant) que el CDN no conoce.
#
# LAS 4 PRIMITIVAS DE RACK::ATTACK:
#   safelist  -> permitir SIEMPRE (se evalúa primero; salud, IPs internas)
#   blocklist -> denegar SIEMPRE
#   throttle  -> contar y limitar por ventana de tiempo
#   track     -> sólo medir, sin bloquear (ideal para calibrar antes de activar)
# ==============================================================================

# ------------------------------------------------------------------------------
# `Rack::Attack::Request` hereda de `Rack::Request` y NO trae `remote_ip`:
# `Rack::Request#ip` devuelve la IP del peer TCP. Como insertamos el middleware
# DESPUÉS de ActionDispatch::RemoteIp (ver config/application.rb), en el env ya
# está `action_dispatch.remote_ip` con la IP REAL del cliente, resuelta contra
# la lista de proxies de confianza. Este helper la expone.
#
# Reabrir una clase de otra librería para agregarle un método es MONKEY PATCHING,
# y en Ruby es una herramienta legítima (acá la propia documentación de
# rack-attack lo recomienda). Pero es poderosa y peligrosa: si dos gemas parchean
# el mismo método, gana la última cargada y el bug es infernal de encontrar.
# Regla: parcheá sólo cuando la librería lo prevé, y dejá el comentario que
# explique por qué.
class Rack::Attack
  class Request < ::Rack::Request
    def remote_ip
      @remote_ip ||= (env["action_dispatch.remote_ip"] || ip).to_s
    end
  end
end

class Rack::Attack
  # ---------------------------------------------------------------------------
  # EL STORE DE CONTADORES: la decisión más importante y la que más se equivoca.
  #
  # Rack::Attack guarda "cuántas requests lleva esta IP en esta ventana" en un
  # cache. Si usás un MemoryStore, cada proceso de Puma tiene SU PROPIO contador.
  # Con 4 workers, un límite de 100 se convierte en 400 reales — y encima
  # inconsistente, porque el balanceo entre workers no es uniforme.
  #
  # El store TIENE que ser COMPARTIDO y ATÓMICO:
  #   * Redis (lo que usamos): INCR es atómico y el TTL lo maneja Redis.
  #   * Memcached: idem.
  #   * Solid Cache (Postgres): funciona, pero son 1-2 escrituras por request
  #     contra tu base principal. Para rate limiting de alto volumen, mala idea.
  #
  # Además necesitás `increment` con TTL: no todos los stores lo implementan bien.
  # ---------------------------------------------------------------------------
  self.cache.store =
    if ENV["REDIS_URL"].present?
      ActiveSupport::Cache::RedisCacheStore.new(
        url: ENV["REDIS_URL"],
        namespace: "rack-attack",
        # Si Redis se cae, NO queremos tirar abajo la app entera: `error_handler`
        # deja pasar la request. Es "fail open". Decisión consciente: preferimos
        # servir tráfico sin límite un rato antes que un 500 masivo.
        # Si tu amenaza principal es el abuso y no la caída, elegí "fail closed".
        error_handler: ->(method:, returning:, exception:) {
          Rails.logger.error("[RackAttack] Redis caído (#{method}): #{exception.class}")
        },
        connect_timeout: 1, read_timeout: 0.2, write_timeout: 0.2
      )
    else
      Rails.logger.warn(
        "[RackAttack] Sin REDIS_URL: usando MemoryStore. " \
        "Los contadores NO se comparten entre procesos; los límites reales " \
        "quedan multiplicados por la cantidad de workers. NO USAR EN PRODUCCIÓN."
      )
      ActiveSupport::Cache::MemoryStore.new
    end

  # ---------------------------------------------------------------------------
  # SAFELIST — se evalúa primero y corta todo lo demás.
  # ---------------------------------------------------------------------------

  # El health check del load balancer nunca puede ser limitado: si lo limitás,
  # el balanceador saca la instancia de rotación y te cae el servicio solo.
  safelist("permitir health checks") do |req|
    req.path == "/up" || req.path == "/health"
  end

  # Assets estáticos: los sirve Thruster/CDN, no tienen costo de app.
  safelist("permitir assets") do |req|
    req.path.start_with?("/assets/", "/packs/")
  end

  # Red interna (otros servicios del cluster). `IPAddr#include?` maneja CIDR.
  INTERNAL_NETWORKS = ENV.fetch("INTERNAL_CIDRS", "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16")
                         .split(",").map { |c| IPAddr.new(c.strip) }.freeze

  safelist("permitir red interna") do |req|
    INTERNAL_NETWORKS.any? { |net| net.include?(req.remote_ip) }
  rescue IPAddr::InvalidAddressError
    false
  end

  # ---------------------------------------------------------------------------
  # BLOCKLIST — bloqueo permanente/adaptativo.
  # ---------------------------------------------------------------------------

  # `Fail2Ban` es un bloqueo ADAPTATIVO: si una IP dispara N eventos "sospechosos"
  # dentro de `findtime`, queda bloqueada durante `bantime` — para TODO, no sólo
  # para la ruta que disparó la alarma. Es la contramedida contra el escaneo
  # automatizado (sondas de /wp-admin, /.env, /.git/config).
  blocklist("bloquear escaneo de vulnerabilidades") do |req|
    Rack::Attack::Fail2Ban.filter("scanners-#{req.remote_ip}", maxretry: 3,
                                                               findtime: 10.minutes, bantime: 1.hour) do
      CGI.unescape(req.query_string).include?("/etc/passwd") ||
        req.path.include?("..") ||
        req.path.match?(%r{\A/(wp-admin|wp-login|\.env|\.git|phpmyadmin|vendor/phpunit)}i)
    end
  end

  # ---------------------------------------------------------------------------
  # THROTTLES — el corazón del rate limiting.
  #
  # ALGORITMO: Rack::Attack usa VENTANA FIJA (fixed window). El período se
  # calcula como `Time.now.to_i / period`, o sea que las ventanas están alineadas
  # al reloj absoluto.
  #
  # SU DEFECTO, y hay que saberlo: el "borde de ventana". Con un límite de
  # 100/minuto, un cliente puede mandar 100 requests a las 12:00:59 y otras 100
  # a las 12:01:00 => 200 requests en 1 segundo, sin violar la regla.
  #
  # Alternativas (para responder "¿y cómo lo mejorarías?"):
  #   * Sliding window log: guardás el timestamp de cada request. Exacto pero
  #     caro en memoria (O(n) por cliente).
  #   * Sliding window counter: interpolás entre la ventana actual y la anterior.
  #     Buen equilibrio; es lo que usa Cloudflare.
  #   * TOKEN BUCKET: un balde que se rellena a tasa constante. Permite RÁFAGAS
  #     controladas (que es lo que querés para clientes legítimos) y es el que
  #     usan casi todas las APIs serias (Stripe, AWS). Se implementa en Redis
  #     con un script Lua para que sea atómico.
  # ---------------------------------------------------------------------------

  # Límite general por IP: la red de contención de todo lo demás.
  throttle("req/ip", limit: 300, period: 5.minutes, &:remote_ip)

  # ── Login: el endpoint más atacado de cualquier app ────────────────────────
  # Dos límites en paralelo, y esto es un patrón que conviene explicar:
  #
  #   a) Por IP -> frena el credential stuffing (un atacante probando miles de
  #      pares usuario/clave desde una máquina).
  #   b) Por EMAIL -> frena el ataque distribuido contra UNA cuenta (un botnet
  #      con 5000 IPs probando claves de ana@empresa.com). El límite por IP no
  #      lo detecta porque cada IP hace 2 requests.
  #
  # Necesitás LOS DOS. Cubren amenazas distintas.
  throttle("logins/ip", limit: 5, period: 20.seconds) do |req|
    req.remote_ip if req.path == "/session" && req.post?
  end

  throttle("logins/email", limit: 6, period: 15.minutes) do |req|
    if req.path == "/session" && req.post?
      # `normalizamos` la clave para que "Ana@X.com" y "ana@x.com " cuenten
      # juntas; si no, el atacante evade el límite cambiando el casing.
      req.params.dig("session", "email_address")&.to_s&.downcase&.strip&.presence
    end
  end

  # Reset de contraseña: mismo razonamiento (y además cada request manda un mail,
  # o sea que es un vector de spam y de costo real).
  throttle("password-resets/email", limit: 3, period: 1.hour) do |req|
    req.params.dig("password", "email_address")&.to_s&.downcase&.strip&.presence if req.post? && req.path == "/passwords"
  end

  # ── API: límite POR TOKEN, no por IP ──────────────────────────────────────
  # Los clientes de API suelen estar detrás de NAT/proxy y comparten IP. Limitar
  # por IP castigaría a todos por culpa de uno. La identidad correcta es la
  # CREDENCIAL. Hasheamos el token para no dejar secretos en las claves del cache
  # (que se ven en Redis, en logs y en dashboards).
  throttle("api/token", limit: 1_000, period: 1.hour) do |req|
    next unless req.path.start_with?("/api/")

    if (auth = req.get_header("HTTP_AUTHORIZATION")) && auth.start_with?("Bearer ")
      Digest::SHA256.hexdigest(auth.delete_prefix("Bearer "))
    else
      # Sin token: límite mucho más agresivo por IP. Una API sin credencial no
      # tiene por qué recibir mucho tráfico.
      "anon-#{req.remote_ip}"
    end
  end

  # Las ESCRITURAS cuestan mucho más que las lecturas (locks, WAL, jobs).
  # Merecen su propio límite, más bajo. Cobrar distinto según el costo real del
  # endpoint es lo que separa un rate limit de juguete de uno pensado.
  throttle("api/writes", limit: 120, period: 1.minute) do |req|
    next unless req.path.start_with?("/api/") && !req.get? && !req.head?

    (req.get_header("HTTP_AUTHORIZATION").presence &&
      Digest::SHA256.hexdigest(req.get_header("HTTP_AUTHORIZATION"))) || req.remote_ip
  end

  # ── TRACK: medir sin bloquear ─────────────────────────────────────────────
  # Antes de activar un límite nuevo en producción, lo dejás en `track` un par de
  # semanas y mirás cuántos clientes LEGÍTIMOS lo habrían tocado. Activar un
  # límite a ciegas es la forma más rápida de romperle la integración a un cliente.
  track("api/heavy-reports", limit: 20, period: 1.minute) do |req|
    req.remote_ip if req.path.start_with?("/api/v1/reports/")
  end

  # ---------------------------------------------------------------------------
  # RESPUESTA AL BLOQUEO
  #
  # Un 429 SIN cabeceras es hostil: el cliente no sabe cuánto esperar y reintenta
  # en loop, empeorando todo. Devolver `Retry-After` + las cabeceras `RateLimit-*`
  # (RFC 9331) permite que un cliente bien hecho haga backoff solo.
  # ---------------------------------------------------------------------------
  self.throttled_responder = lambda do |request|
    match = request.env["rack.attack.match_data"] || {}
    now = Time.now.to_i
    period = match[:period].to_i
    limit = match[:count].to_i
    retry_after = period.positive? ? (period - (now % period)) : 60

    [
      429,
      {
        "Content-Type" => "application/json; charset=utf-8",
        "Retry-After" => retry_after.to_s,
        "RateLimit-Limit" => match[:limit].to_s,
        "RateLimit-Remaining" => [ match[:limit].to_i - limit, 0 ].max.to_s,
        "RateLimit-Reset" => retry_after.to_s
      },
      [ {
        error: {
          code: "rate_limit_exceeded",
          message: "Demasiadas solicitudes. Reintentá en #{retry_after} segundos.",
          details: { retry_after:, limit: match[:limit], window_seconds: period }
        }
      }.to_json ]
    ]
  end

  self.blocklisted_responder = lambda do |_request|
    [ 403, { "Content-Type" => "application/json" },
      [ { error: { code: "forbidden", message: "Acceso bloqueado." } }.to_json ] ]
  end
end

# ------------------------------------------------------------------------------
# OBSERVABILIDAD: sin esto, el rate limiting es una caja negra y el día que un
# cliente diga "me están cortando" no vas a tener con qué responder.
# ActiveSupport::Notifications es el bus de eventos interno de Rails (el mismo
# que usan los logs de queries y de render).
# ------------------------------------------------------------------------------
ActiveSupport::Notifications.subscribe(/rack_attack/) do |name, _start, _finish, _id, payload|
  req = payload[:request]
  next if req.nil?

  match_type = req.env["rack.attack.match_type"]
  next unless %i[throttle blocklist].include?(match_type)

  Rails.logger.warn(
    event: "rack_attack.#{match_type}",
    rule: req.env["rack.attack.matched"],
    ip: req.remote_ip,
    path: req.path,
    method: req.request_method,
    user_agent: req.user_agent&.truncate(120),
    discriminator: req.env["rack.attack.match_discriminator"].to_s.truncate(64)
  )
end

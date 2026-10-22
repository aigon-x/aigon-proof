# Wzorce mcp-config.json — zmierzone 2026-09-30 (<workspace>)

Dwa działające kształty. Kopiuj i podmień `<...>`. Rejestracja runtime skanuje
`<workspace>/mcp-servers/servers/**/mcp-config.json` (funkcja `load_mcp_servers`
w `runtime/crates/aigon-runtime/src/api.rs`).

---

## A. Serwer Node (bez shimu)

Node SDK toleruje brak handshake `initialize`, więc runtime może go wołać wprost.

```json
{
  "id": "brave-search",
  "name": "brave-search",
  "transport": "stdio",
  "command": "node",
  "args": ["build/index.js"],
  "cwd": "/app",
  "timeout_secs": 60,
  "tags": ["search", "web", "brave", "tool:brave_web_search", "contract:README.md"]
}
```

Uwagi:
- `cwd` = katalog, w którym leży `mcp-config.json` (serwer + build). Runtime ustawia
  cwd z tego pola — ścieżka `build/index.js` jest RELATYWNA do `cwd`.
- `tags` z prefiksem `tool:<nazwa>` dokumentują wystawiane narzędzia; `contract:README.md`
  wskazuje plik z kontraktem (konwencja AIGON).

---

## B. Serwer Python (PRZEZ SHIM — wymagany)

Python MCP SDK odrzuca żądanie bez handshake. Shim robi `initialize` +
`notifications/initialized` za runtime i przekazuje dalej.

```json
{
  "id": "maddy-mail",
  "name": "maddy-mail",
  "transport": "stdio",
  "command": "/usr/bin/python3",
  "args": [
    "<workspace>/mcp-servers/lib/mcp_stdio_shim.py",
    "/usr/bin/python3",
    "<workspace>/mcp-servers/servers/mail/maddy-mail/server.py"
  ],
  "cwd": "<workspace>/mcp-servers/servers/mail/maddy-mail",
  "timeout_secs": 60,
  "tags": ["mail", "email", "maddy", "imap", "read-only",
           "contract:README.md",
           "tool:mail_folders", "tool:mail_list", "tool:mail_search",
           "tool:mail_read", "tool:mail_thread"]
}
```

Kolejność `args` ma znaczenie:
`[shim.py, <interpreter serwera>, <ścieżka serwera>, ...opcjonalne]`.
Shim spawnuje `<interpreter> <ścieżka>` jako dziecko.

**Alternatywa dla serwera spoza repo (np. z venv pakietu):**

```json
{
  "id": "crawl4ai",
  "transport": "stdio",
  "command": "/usr/bin/python3",
  "args": [
    "<workspace>/mcp-servers/lib/mcp_stdio_shim.py",
    "<workspace>/.venv-ytdlp/bin/python",
    "<workspace>/mcp-servers/servers/web/crawl4ai/server_entry.py"
  ]
}
```

---

## C. Serwer HTTP (nie stdio)

Gdy serwer wystawia własny transport HTTP (np. własny endpoint JSON-RPC), rejestracja
idzie do `config/agent-models.yaml` → sekcja `mcp_servers`, nie do katalogu `servers/`:

```yaml
mcp_servers:
  magic-router:
    type: http
    url: http://127.0.0.1:17002/mcp/message
    auth_token_file: config/secrets/agent-mcp.token
```

**PUŁAPKA:** brak `auth_token_file` = defekt uśpiony. `sync_*_mcp` rozwiązują
nagłówki WYŁĄCZNIE z `headers`/`auth_token_file`; bez tego pola konfig u konsumenta
dostaje **401** („Auth required"). Zmierzone: `magic-router` bez tego pola → 401 u
każdego konsumenta, mimo że ręczny `curl` z tokenem działał.

---

## Czego NIE wkładać pod `servers/`

Plik w formacie **klienta** (Claude Desktop) zeruje CAŁY rejestr:

```json
{ "mcpServers": { "x": { "command": "...", "args": [] } } }
```

`load_mcp_servers` przerywa na pierwszym błędzie — jeden taki plik pod `servers/`
sprawia, że **żaden** proxy-tool MCP nie działa. Zmierzone 2026-09-22:
`servers/core/deepseek/config/mcp-config.json` zerował rejestr.
Konfigi klienckie → `mcp-servers/clients/`.

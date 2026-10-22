---
name: mcp-server-authoring-and-registration
description: "Autorstwo i REJESTRACJA nowego serwera MCP w stacku AIGON (<workspace>) — kontrakt stdio przez lib/mcp_stdio_shim.py, kształt mcp-config.json, oraz CZTERY miejsca rejestracji, bez których serwer jest SIEROTĄ (mcp-config.json, mcp-servers/MANIFEST.yaml, runtime/manifests/capabilities.yaml, CANONICALITY.yaml) + skill. Użyj, gdy dodajesz nowe narzędzie/klienta (poczta, git, API, baza) jako serwer MCP, gdy istniejący serwer jest zarejestrowany ale każde wywołanie pada, gdy serwer nie pojawia się w katalogu u agenta, albo gdy user pyta „dodałeś do manifestu i kanonu?\"."
version: 1.0.0
author: AIGON
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [mcp, serwer-mcp, rejestracja, kanon, manifest, stdio, shim, aigon]
---


# Autorstwo i rejestracja serwera MCP (AIGON <workspace>)

## Kiedy używać

- Dodajesz nową zdolność jako serwer MCP (klient poczty, git, API, baza, scraping).
- Serwer jest w rejestrze, ale **każde wywołanie pada** błędem protokołu.
- Serwer działa lokalnie, ale **nie widać go u agenta** (`skills_list` / katalog).
- User pyta wprost: „a dodałeś capability i skilla do manifestu i kanonu?"

**Zasada nadrzędna:** napisane = PODPIĘTE. Serwer bez kompletu rejestracji to
sierota — kod leży, nikt go nie woła, a bramka `no-dangling-reference`/`wired-check`
prędzej czy później to wykaże.

## KROK 0 — ZAPYTAJ REJESTR, ZANIM NAPISZESZ

Zanim stworzysz nowy serwer, sprawdź, czy narzędzie już nie istnieje:
`capabilities_list` (MCP), `skills_list`, `mcp-servers/MANIFEST.yaml`.
Narzędzie, które już istnieje, wygrywa. Dopisz/wywołaj zamiast duplikować.

## KROK 1 — STRUKTURA KATALOGU

```
<workspace>/mcp-servers/servers/<kategoria>/<nazwa>/
├── server.py           # implementacja (stdlib-only, gdy się da)
├── mcp-config.json     # rejestracja runtime (load_mcp_servers)
└── README.md           # kontrakt + PUŁAPKI zmierzone
```

Kategoria to podkatalog (`search/`, `mail/`, `git/`, `security/`) — runtime
skanuje `servers/**/mcp-config.json`.

## KROK 2 — USTAL TRANSPORT: Node toleruje, Python wymaga shimu

Runtime (`aigon-mcp-transport`, `call_stdio`) spawnuje serwer **per wywołanie**
i wysyła **JEDNO** żądanie klienta **bez handshake `initialize`**.

| Serwer napisany w | Zachowanie | Rozwiązanie |
|---|---|---|
| Node SDK (brave-search) | toleruje brak handshake | `command: node`, `args: [build/index.js]` |
| Python MCP SDK (crawl4ai, fetch) | **odrzuca**: „Received request before initialization was complete" | idź przez **shim** |

**Shim** (`<workspace>/mcp-servers/lib/mcp_stdio_shim.py`,stdlib-only) robi
`initialize` → `notifications/initialized` wobec prawdziwego serwera, przekazuje
żądanie klienta i wypisuje jedną odpowiedź. Bez niego serwer jest ZAREJESTROWANY,
ale **każde wywołanie pada** — cichy fałszywy zielony.

```json
{
  "id": "maddy-mail",
  "name": "maddy-mail",
  "transport": "stdio",
  "command": "/usr/bin/python3",
  "args": ["<workspace>/mcp-servers/lib/mcp_stdio_shim.py",
           "/usr/bin/python3",
           "<workspace>/mcp-servers/servers/mail/maddy-mail/server.py"],
  "cwd": "<workspace>/mcp-servers/servers/mail/maddy-mail",
  "timeout_secs": 60,
  "tags": ["mail", "read-only", "tool:mail_read"]
}
```

## KROK 3 — KONTRAKT SERWERA (implementacja)

- Obsłuż `initialize` (zwróć `protocolVersion`, `capabilities.tools`, `serverInfo`),
  ignoruj `notifications/*`, obsłuż `tools/list` i `tools/call`.
- **Diagnostyka TYLKO na stderr** — stdout jest zarezerwowany na JSON-RPC.
- Na błąd narzędzia wypisz na stderr linię ze znacznikiem `AIGON_TOOL_ERROR <powód>`.
  Shim wyłuskuje ją i dokłada do komunikatu — bez tego `ok=false` nie mówi DLACZEGO.
- Łatka do szybkiego testu bez MCP:
  ```bash
  python3 server.py --call <narzędzie> '{"arg":"wartość"}'
  ```

## KROK 4 — CZTERY MIEJSCA REJESTRACJI (+ skill)

To jest krok, który się pomija i potem się dziwi. **Rejestracja w jednym
miejscu = sierota.** Wszystkie cztery plus skill:

| # | Plik | Wpis | Po co |
|---|---|---|---|
| 1 | `servers/<kat>/<nazwa>/mcp-config.json` | pełny obiekt (wyżej) | runtime `load_mcp_servers()` |
| 2 | `mcp-servers/MANIFEST.yaml` | `registry: - id: <nazwa>` | inwentarz serwerów + bramki |
| 3 | `runtime/manifests/capabilities.yaml` | `- name: mcp:<nazwa>`, `backend: mcp`, `enabled: true` + `description` z KIEDY | katalog `capabilities_list` |
| 4 | `CANONICALITY.yaml` (sekcja `domain_authority`) | `mcp_<nazwa_z_podkreśleniami>: <ścieżka>` + komentarz kanonu | kanon/SSOT |
| 5 | `skills/shared/<nazwa>/SKILL.md` | procedura + PUŁAPKI | agent wie, JAK użyć |

**Uwaga na konwencję klucza w CANONICALITY:** myślniki → podkreślenia
(`maddy-mail` → `mcp_maddy_mail`); sekcja to `domain_authority`, obok
`skille_dla_mcp`, `mail_stack`. Weryfikuj ZAGNIEŻDŻENIE, nie grep top-level:

```bash
python3 -c "
import yaml; d=yaml.safe_load(open('CANONICALITY.yaml'))
print('mcp_maddy_mail' in d['domain_authority'])"   # NIE: ... in d
```

## KROK 5 — WERYFIKACJA (ad-hoc, nie „powinno działać")

```bash
# 1. pełny handshake przez shim — czy widzi narzędzia
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | \
  python3 mcp-servers/lib/mcp_stdio_shim.py /usr/bin/python3 \
  mcp-servers/servers/<kat>/<nazwa>/server.py
# → {"result":{"tools":[{"name":"...", ...}]}}

# 2. wywołanie realnego narzędzia (dowód, że NIE jest rejestrem-atrapą)
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"<n>","arguments":{...}}}' | \
  python3 mcp-servers/lib/mcp_stdio_shim.py ... server.py

# 3. po deployu — to samo NA WĘŹLE (nie tylko lokalnie)
ssh prod-aigon 'echo "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}" | \
  timeout 30 python3 <workspace>/mcp-servers/lib/mcp_stdio_shim.py ... '
```

## PUŁAPKI (każda zmierzona)

### 1. Katalog `servers/**/mcp-config.json` w OBECNYM formacie klienta zeruje CAŁY rejestr
`load_mcp_servers` **przerywa na pierwszym błędzie**. JEDEN plik w formacie
Claude Desktop (`{"mcpServers": {...}}`) pod `servers/` wywala rejestrację —
wszystkie proxy-tool MCP przestają działać. Konfigi **klienckie** trzymaj w
`mcp-servers/clients/`, nie pod `servers/`.

### 2. Python bez shimu = zarejestrowany, ale martwy
Objaw: `tools/list` → 200, a `tools/call` → `Invalid request parameters` /
`Received request before initialization was complete`. Diagnoza: brak handshake.
Leczenie: `mcp_stdio_shim.py` (KROK 2).

### 3. `.gitignore` z regułą bez kotwicy zjada kod serwera
Reguła `mail/` (bez wiodącego `/`) łapie **każdy** katalog `mail/` w drzewie —
w tym `mcp-servers/servers/mail/`. Kotwiczenie `/mail/` ma jednak efekt uboczny:
blokuje też `git add` plików **śledzonych**. Poprawnie:
```gitignore
/mail/
/mail/*
!/mail/maddy.conf
```
Test: `git check-ignore -q <plik>` → rc=0 = ignorowany.

### 4. `write_file` zostawia `0600` → serwer nieczytelny dla runtime
Po `write_file` w `<workspace>` plik bywa `aigon:aigon 0600` → `git add` „Brak dostępu"
i runtime nie odczyta. **Zawsze po `write_file`:**
```bash
sudo chown aigon:aigon <plik> && sudo chmod 644 <plik>
```
`chown` bez `chmod` zostawia 600. Szczegóły: `shared-user-file-permissions`.

### 5. Dwa serwery MCP o tej samej nazwie na różnych węzłach
Gateway (`:17002`) **deduplikuje** i dokłada własne — liczba narzędzi w agregacie
NIE jest sumą. `servers_total: 8, servers_connected: 7` z powodu jednego offline
jest poprawne, nie sprzeczne.

## Powiązane
- `shared-user-file-permissions` — tryby/właściciel po `write_file`.
- `infra-ssot-drift-before-fix` — deploy przez sync-prod, md5 na węzłach.
- `verification-guard-integrity` — jak NIE ogłosić zielonego bez pomiaru.
- `mcp-server-provisioning` — dostarczenie PLIKÓW na węzły (inna klasa).
- `mcp-server-discovery` — inwentaryzacja istniejących (inna klasa).

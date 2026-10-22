---
name: mcp-lane-registry-parity
description: Use when narzędzia/metadane MCP „nie przechodzą" przez bramę, gdy klient widzi inny katalog tooli niż backend, albo gdy po zmianie bramy (router/gateway) „czegoś nie ma". Audyt parytetu rejestrów między lane'ami MCP (backend :38080 vs brama :17002 vs mcp-rs :31704) — pomiar, diff, atrybucja źródła, dopiero potem naprawa.
version: 1.0.0
metadata:
  hermes:
    tags: [mcp, gateway, registry-parity, magic-router, aigon]
    related_skills: [mcp-tool-discovery, mcp-tools-mass-test, mcp-gateway-full-mesh-recovery, mcp-server-discovery]
---


# Parytet rejestrów MCP między lane'ami

Jeden system, kilka wejść do MCP. Każde wejście ma WŁASNY katalog narzędzi, więc
„narzędzie zniknęło" najczęściej znaczy „ta ścieżka czyta inny rejestr", a nie
„ktoś usunął kod". Ten skill mierzy to zanim cokolwiek naprawisz.

## Kiedy używać

- Suweren/użytkownik mówi: „coś chujowo przechodzą metadane", „czegoś nie ma",
  „brakuje routera", „miał to aigon-code-server", „klient widzi mniej narzędzi".
- Po zmianie bramy (nowy upstream, `gateway.yaml`, nowy node) — zanim uznasz zmianę
  za udaną.
- Gdy `tools/list` działa, ale model/klient zachowuje się jakby brakowało mu
  narzędzi (git-mcp, fetch, rea, filesystem itd.).
- Przed meldunkiem „wszystko spięte" — parytet jest dowodem, nie deklaracją.

## Mapa lane'ów (AIGON, zmierzone 2026-10-19)

| Lane | Adres | Protokół / auth | Rejestr |
|---|---|---|---|
| Backend (klienci lokalni, Hermes) | `http://127.0.0.1:38080/mcp` — proces `aigon-code-server` (bind <host>:38080) | HTTP, Bearer JWT | rejestr tooli code-servera: 101 narzędzi, w tym WSZYSTKIE proxy `mcp_*_call` |
| Brama (Magic Router) | `http://127.0.0.1:17002/mcp/message` — proces `aigon-x-magic-router`, kontener `aigon-core-router`, `network_mode=host` | **HTTP, nie HTTPS**; `Authorization: Bearer <agent-mcp.token>` | własny katalog: 99 narzędzi z capability runtime (`vuln_scan`, `iac_audit`, `filesystem`, `vision`, …) |
| mcp-rs per node | `https://<node>:31704` | HTTPS; `/mcp` → 404, `/mcp/message` → 401 dla tokenu bramy (inna płaszczyzna auth) | rejestr code-mcp-<node> |

Router NIE jest serwerem MCP o nazwie „router" — router JEST bramą. Lista jego
upstreamów: `<workspace>/core/router/gateway.yaml`, sekcja `mcp_servers:` →
`code-mcp-local / -prod / -contabo / -monitor / -site / -optiq` (`code-mcp-mail`
wyłączony, node martwy). „Brak routera" ≠ brak wpisu; sprawdź tę listę, potem
diff narzędzi.

## Procedura

1. **Policz oba katalogi, z czasem.** Trzy próby `tools/list` na każdym lane'ie
   (`scripts/mcp-registry-diff.py` robi to razem z diffem). Czas 0,5–0,7 s =
   brama zdrowa; timeout/000 = problem transportu, nie rejestru.
2. **Znormalizuj odpowiedź SSE.** Odpowiedź to `data: {...}` — sklej WSZYSTKIE
   linie `data:`. Wzięcie tylko ostatniej daje `JSONDecodeError: Extra data`.
3. **Zrób diff zbiorów nazw w OBIE strony** (backend − brama, brama − backend).
   Jedna strona to zwykle „proxy `mcp_*_call`", druga „capability runtime".
4. **Przypisz źródło każdej brakującej nazwy**, zanim nazwiesz to defektem:
   - `mcp_*_call`, `mesh_nodes`, `runtime_status`, `sessions_*`, `voice_*` →
     rejestr backendu (`products/aigon-code/backend-rs/src/handlers/mcp.rs`, `tools.rs`).
   - `filesystem`, `vuln_scan`, `iac_audit`, `vision`, `research` → katalog
     capability runtime (`runtime/manifests/capabilities.yaml`).
5. **Rozstrzygnij kierunek naprawy** (nie wyciszaj): albo brama dostaje brakujące
   proxy z rejestru backendu, albo backend dostaje sekcję capability — decyzja
   zależy od tego, KTO ma widzieć narzędzie (klient lokalny vs zewnętrzny).
   Zapisz wybór w `gateway.yaml` komentarzem z datą — to jedyne miejsce, gdzie
   następny agent zobaczy intencję.

## Pitfalls (zmierzone)

- **„Brakuje X" nie znaczy „usunięto X".** 2026-10-19: brakowało 22 narzędzi
  (git-mcp, fetch, context7, brave-search, exa, crawl4ai, browser-render,
  owner-osint, switch-commands, task-manager, rea) — nie dlatego, że ktoś je
  skasował, tylko dlatego, że brama czyta inny rejestr. Diff przed naprawą.
- **SSE: sklejaj `data:`, nie bierz ostatniej linii.** Inaczej 26 KB odpowiedzi
  „nie parsuje się" i wygląda jak awaria narzędzia.
- **HTTPS na :17002 daje `http=000`.** To nie „brama padła" — ten port mówi po
  HTTP. Sprawdź `http://` zanim ogłosisz czerwien.
- **Token bramy ≠ token runtime.** `config/secrets/agent-mcp.token` działa na
  :17002; na :31704 daje 401 (inna płaszczyzna). Nie „naprawiaj" tego podmianą.
- **Metadane psują się od obciążenia, nie od rejestru.** Gdy `tools/list` jest
  szybki, a klient gubi narzędzia, sprawdź `/v1/chat/completions` (429/500/499)
  i log code-servera (`read header from client timeout`,
  `mesh presence: discovery unavailable`) — objaw przeciążonego węzła wygląda
  identycznie jak brak rejestru.
- **Nie ogłaszaj „router missing" po nazwie.** Najpierw `ss -ltnp | grep 17002`
  (kto słucha) + `gateway.yaml mcp_servers:`.

## Raportowanie Suwerenowi

Najpierw liczby (ile aktywnych alertów, ile narzędzi w każdym lane'ie, czasy),
potem JEDNO zdanie werdyktu („brama sprawna, katalog rozjechany"), potem kolejność
naprawy. Bez pytań „co dalej" — deklarujesz priorytet i zaczynasz od pierwszego.

## Pliki

- `scripts/mcp-registry-diff.py` — pobiera `tools/list` z backendu i bramy,
  skleja SSE, robi diff w obie strony, mierzy czasy. Uruchom:
  `python3 scripts/mcp-registry-diff.py` (opcjonalnie `--backend URL --gateway URL`).
- `references/aigon-lane-registry-audit-2026-10-19.md` — pełny zapis pomiaru
  (101 vs 99, listy brakujących, topologia, logi).

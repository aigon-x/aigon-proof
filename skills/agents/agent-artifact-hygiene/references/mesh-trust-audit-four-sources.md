# Badanie mesha — METODA CZTERECH ŹRÓDEŁ i rozstrzyganie rozbieżności

Sesja 2026-09-28, AIGON-X. Zlecenie: „trzeba zwołać mesha i przeprowadzić badanie".
Wynik: root cause pustego `mesh_nodes` w MCP znaleziony **przed** zwolaniem swarmu,
bo najpierw sprawdzono, czy narzędziu badawczemu można wierzyć.

## Metoda: mierz z czterech niezależnych warstw

| Źródło | Co mierzy | Komenda |
|---|---|---|
| A — rejestr aplikacji | mesh z perspektywy mastera | `GET https://<host>:7000/api/v1/mesh` (sekcja `mesh`, `nodes`, `alerts`, `ha`, `matrix`) |
| B — transport | warstwa sieciowa pod aplikacją | `tailscale status` |
| C — bezpośrednia żywotność | czy każdy node odpowiada | `curl -sk https://<ip>:7000/health` per node |
| D — narzędzie MCP dla agentów | co WIDZI agent pytający o mesh | `mesh_nodes`, `mesh_node_audit` |

**Zasada nadrzędna: rozbieżność między źródłami jest ZNALEZISKIEM, nie szumem.**
Nie uśredniaj, nie wybieraj wygodniejszego — rozstrzygnij, KTÓRE jest autorytetem
dla danego pytania, i nazwij to w raporcie.

## Zderzenie, które dało wynik (zmierzone)

| Źródło | Odpowiedź | Prawda? |
|---|---|---|
| A `GET /api/v1/mesh` | 9 nodów, 6 up, quorum=true, 20 alertów | ✅ AUTORYTET |
| A' `GET /api/v1/mesh/nodes` (HTTP) | 9 nodów z pełnym hardware | ✅ (inny widok tego samego) |
| B tabela `mesh_nodes` (Postgres) | 6 wierszy z 2026-08-01, wszystkie `0.0.0.0` | ❌ 58-dniowe zwłoki |
| C MCP `mesh_nodes` | `nodes: []`, `total_nodes: 0` | ❌ FAŁSZYWY WYNIK |

**Czwarte źródło było ślepe, choć dane istniały.** Agent pytający przez MCP
dostawał `[]` i wnioskował „mesha nie ma" — klasa fałszywego wyniku = P0.

## Nie ufaj inwentarzowi nazw — dwa rejestry, te same maszyny

Rejestr mesha i Tailscale używają **różnych nazw**. Dopasowanie po nazwie dało
błędne wnioski w pierwszej wersji raportu (nazwano N2 „kamil-dev", N7 „aigon-dev").

| Rejestr mesha (autorytet) | Tailscale |
|---|---|
| `kamil-aigon` | `kamil-dev` |
| `poligon-aigon` | `aigon-dev` |
| `mail-aigon` | `mail` |
| `monitor-aigon` | `aigon-monitor` |
| `optiq-aigon` | `optiq-ai` |
| `site-aigon` | `aigon-site` |

**Reguła:** dla pytania o mesh autorytetem jest REJESTR MESHA. Tailscale to
warstwa transportu — przydatna do diagnozy (patrz niżej), NIE do identyfikacji.

## Rozjazd warstw: „node offline" vs „aplikacja martwa"

Pomiar, który to rozdziela:
- Tailscale: `active; direct 62.171.189.172:41641, tx 441185768 rx 227706596` → **sieć ŻYJE**
- `curl https://<ip>:7000/health` → **000** → **aplikacja NIE odpowiada**

To NIE jest „node offline". To rozjazd warstw. Klasa: zakleszczenie procesu
(`aigon-runtime-bind-deadlock-diagnosis`) albo niedobór CPU na obsługę żądania.
KOREKTA: wcześniejsza notatka mówiła „sshd+runtime MARTWE → wymaga konsoli VMI";
pomiar przyrostu rx/tx obalił hipotezę „host offline".

## Root cause pustego presence — pełny łańcuch (wzorzec do rozpoznawania)

```
funkcja zapisu własności ISTNIEJE, ale ZERO wołających   ← presence.rs:366 (sierota)
        ↓
owner:* = 0 kluczy w Redisie
        ↓
record_heartbeat: brak ownera → return Ok(None)          ← CICHY brak zapisu
        ↓
node:*:last_seen = 1 klucz (przeżył tylko inny pisarz)
        ↓
list_online_nodes: filtr tenant + capacity_known         ← presence.rs:613
        ↓
mesh_nodes (MCP) → []                                    ← bez POWODU
        ↓
agent wnioskuje: „mesha nie ma"                          ← FAŁSZYWY WYNIK
```

Dwa pisarze o RÓŻNYCH warunkach wejścia = dwa różne zbiory prawdy:

| Pisarz | Warunek | Zachowanie przy braku |
|---|---|---|
| NATS `record_heartbeat` | wymaga `owner:*` | `Ok(None)` — **cichy brak zapisu** |
| Gossip `record_runtime_gossip` | brak (`unwrap_or(fallback_tenant)`) | zapis zawsze |

**Dowód historyczny, że to obejście objawu:** `git log -S "fallback_tenant"` →
commit `3fed0a9a fix(mesh,ssot): presence z gossipu…`. Fallback dodano, gdy presence
okazał się pusty — a `presence.rs:417` zawiera komentarz autora PRZYZNAJĄCY, że
`record_heartbeat` gubi nody (napisał drugą funkcję zamiast naprawić pierwszą).

**Wzorzec rozpoznawczy:** „naprawa wymienia nazwę na `fallback`/`unlike X`/`workaround`"
→ sprawdź, czy nie jest to obejście objawu. Właściwa naprawa to wpięcie brakującego
zapisu, nie kolejny fallback.

## Sygnały, które NIE są defektem (odnotuj, by nie wracały)

- **`healthy_peers=6` przy 8 pozycjach w `/health`** — 8 + master liczony osobno = 9.
  Spójne, tylko różne zakresy raportowania.
- **`secret_placeholder_hits: []`** — pozytywne, zero placeholderów w sekretach.
- **`config_drift` wszystkie `false`** — brak dryfu. Pozytywne.

## Praktyka raportowania badania

1. **Zapisz baseline PRZED badaniem** (`audit/<temat>-<data>/baseline.md`) — pomiar,
   nie opinia. Każda liczba z surową komendą.
2. **Znaleziska numeruj** (Z-1..Z-n) z priorytetem i pierwszym krokiem diagnostycznym.
3. **Zapisuj domknięcia osobno** (`Z-N-resolved.md`) z pełnym łańcuchem przyczynowym —
   nie mieszaj hipotezy z rozstrzygnięciem.
4. **Popraw baseline, gdy pomiar go obalił** — i NAZWIJ korektę w raporcie
   (np. „pierwsza wersja nazwała N2 kamil-dev — wynik dopasowania po niewłaściwym
   rejestrze"). Korekta zapisana przeciw sobie buduje wartość raportu.
5. **Granice nazwij wprost** — sekcja „czego NIE ustaliłem". Brak danych ≠ zero.
6. **Decyzje właściciela zostaw właścicielowi** — naprawa leży w `products/aigon-code`
   (produkt), nie w `runtime`; nie wykonuj jej sam.

## Kryterium zatrzymania swarmu badawczego

Zanim wyślesz subagentów, sprawdź **czy narzędzie, którym będą badać, nie kłamie**.
Tu: 4 zwiadowców poszło w tle, gdy root cause był już ustalony własnym pomiarem
(4 wywołania narzędzi) — bo najpierw sprawdzono spójność źródeł, a dopiero potem
zwolano siły. Zwołanie swarmu na ślepym narzędziu daje N raportów o niczym.

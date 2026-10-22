# Audyt SIEROT wiringu na poziomie PLIKÓW repo (REPO/SIEROTY)

Klasa zadania: „kataloguj pliki repo i wykryj sieroty wiringu po stronie plików"
— które `.sh/.py/.rs/.ts` w `scripts/` i `tools/` nie są wołane z NICZEGO.
To INNA oś niż §21 (osie wykonania bramki): tam pytasz „kto wykonuje TĘ BRAMKĘ",
tu pytasz „kto WOŁA TEN PLIK".

Read-only. Zero buildów, zero `git add/commit`, zero edycji repo. Skrypty
pomocnicze pisz do `/tmp` albo do katalogu skilla.

## 1. Najpierw — kanoniczny detektor, nie własny od zera

Repo `<workspace>` MA bramkę tej klasy (nie pisz drugiej, dopóki jej nie przeczytasz):

```
bash tools/gates/scripts-wired-check.sh --json    # raport JSON na stdout (read-only)
bash tools/gates/scripts-wired-check.sh --list    # tabela sierot (dla operatora)
bash tools/gates/scripts-wired-check.sh           # 1 linia + 15 FAIL
# --regen PISZE allowlistę (config/canonical/scripts-orphans.json) — NIE używać w audycie read-only
```

Kontrakt: exit 0 = PASS/WARN (każda sierota ma wpis w allowliście), 1 = FAIL
(sierota bez uzasadnienia), 2/3 = błąd środowiska. Skanuje **tylko**
`scripts/*.sh` i `scripts/*.py`.

### Kanały wołania (haystack) — pełna lista, bo „za wąsko" = fałszywy alarm
- `config/cron.yaml`, `config/backups.yaml`, `config/canonical/hooks.yaml`,
  `config/gateways.yaml`, `config/alert-automation-policy.yaml`, … (SSOT-y)
- **WSZYSTKIE** `config/**/*.yaml|yml|json` — **Z WYŁĄCZENIEM `config/generated/`**
- ciała wszystkich `tools/**` (bez `target/.venv/node_modules`), z neutralizacją
  WŁASNEJ nazwy pliku (guard autoreferencji)
- ciała wszystkich `scripts/**`, z neutralizacją własnej nazwy
- runtime: `cat /etc/cron.d/* /etc/crontab` + `grep -rh` po `/etc/systemd/system/*.{service,timer}`
- `docker-compose.yml`, `core/docker-compose.yml`

### Artefakty SSOT tej klasy (sprawdź je, zanim tworzysz nowe)
| Plik | Rola |
|---|---|
| `config/canonical/scripts-orphans.json` | allowlista uzasadnionych sierot (`script`+`class`+`reason`+`wired_by_intent`) |
| `config/canonical/wiring-closure-debt.txt` | ratchet długu domknięcia wiringu (wolno TYLKO zmniejszać) |
| `tools/gates/dangling-reference-allowlist.txt` | świadome odwołania do nieistniejących plików (testy negatywne, skrypty platformy) |
| `tools/gates/reconcile-exempt.txt` | bramki świadomie niewpięte do osi A |
| `config/generated/atlas.generated.yaml` | **INWENTARZ** wszystkich plików — NIE jest kanałem wołania |

## 2. Cztery pułapki (wszystkie zmierzone, każda daje FAŁSZYWY werdykt)

### (a) Inwentarz maskuje — fałszywy ZIELONY
`config/generated/atlas.generated.yaml` to spis WSZYSTKICH skryptów w repo.
Jeśli wliczysz go do haystacku, KAŻDY plik „znajduje się" w nim → 0 sierot →
PASS na martwym kodzie. **Wyklucz cały katalog `config/generated/`.**
(Sam gate ma to w komentarzu jako PUŁAPKA 2.)

### (b) Detektor za wąski na nazwę — fałszywe CZERWONE (tools/gates/*)
Bramki żyją w `hooks.yaml` / `config/canonical/gate-registry.yaml` jako **SHORT
NAME bez rozszerzenia**: `- law-estop`, `- load-profile`, NIE `law-estop.sh`.
Dopasowanie tylko `basename z .sh` daje ~15 fałszywych sierot w `tools/gates/`.
**Dopasowuj `basename` ORAZ `stem`** (nazwa bez ostatniego rozszerzenia).

### (c) Kanał pominięty — fałszywe CZERWONE
Jedynym wołającym bywa `.txt` (allowlista), `.github/workflows/*.yml`, `Makefile`
albo komentarz w innym skrypcie. Zanim ogłosisz sierotę — grep **repo-wide**
(ripgrep), nie po jednym pliku. Ale rozróżniaj: **wzmianka w `docs/`, `reports/`,
`skills/` to NIE kanał wołania** — odnotuj jako „udokumentowany", nie jako „wired".

### (d) Git baseline kłamie, gdy remote nieosiągalny
`git ls-remote origin` / `git fetch` → `Repository not found` ⇒ `origin/main` to
**STALE remote-tracking ref**, a „ahead/behind 4000+" jest BEZ SENSU (nie da się
odświeżyć). Nie raportuj ahead/behind jako stanu. Do podziału **tracked vs WIP**
używaj `git ls-tree -r HEAD --name-only` (NIE `git ls-files` — staged-only to
wciąż praca w toku; patrz `references/detektor-za-szeroki-plik-poza-head.md`).

## 3. Wydajność i zakres (inaczej timeout / eksplozja kandydatów)

- **Nie `grep -r` po całym `<workspace>`** — drzewo z `backups/`, `artifacts/`,
  `products/*/build` itd. timeoutuje 180 s. Użyj ripgrep (`search_files`) albo
  skryptu Py z jawnymi wykluczeniami.
- **Nie rób `name in haystack`** (substring po wielo-MB stringu × ~1000 nazw =
  O(n·m), timeout). Zbuduj raz zbiór tokenów:
  `tokens = set(re.findall(r"[A-Za-z0-9][A-Za-z0-9_.\-]*", hay))` i testuj
  membership (O(1)).
- **Wykluczaj katalogi po PREFIKSIE i typie**: `d.startswith(".venv")` (nie tylko
  `== ".venv"` — `tools/.venv-capability` rozwaliło kandydatów 1446 → 12215),
  `site-packages`, `/lib/py/`, `/vendor/`, `backups`, `artifacts`, `target`.
- **Vendored libs** (np. `tools/gates/lib/py/pypdf/**`) zawsze wychodzą jako
  „sieroty" — raportuj osobno i NIE licz do realnych.

## 4. Klasyfikacja i kształt raportu

Dla każdej sieroty podaj KLASĘ i to, czy jest TRACKED czy WIP:
- `lib` (startswith `lib`/`_`, `source`, importowana przez sąsiada) — OK, nie defekt
- `test` (startswith `test`/`test_`, `/test`) — wpiąć do runnera CI
- `on-demand` / `generator` — narzędzie ręczne (runbook), kandydat na allowlistę
- `vendored` — do odfiltrowania
- `unknown` — do decyzji: wpiąć albo allowlista z uzasadnieniem

Raport: **LICZBY + konkretne ŚCIEŻKI**, nie opis zamiaru. Rozdziel:
`tracked-bez-wpięcia` (realny defekt) od `untracked-WIP` (nie może łamać
kontraktu repo — WARN z nazwą). Zawsze dołącz: total / wired / orphans /
allowlisted / unjustified.

## 5. Wynik referencyjny (sesja 2026-10-12, `<workspace>`)

- `scripts/`: 607 total, 567 wired, 40 sierot — **wszystkie 40 untracked-WIP,
  0 tracked-unjustified → PASS** (kanoniczny gate).
- `tools/`: ~31 realnych sierot po odfiltrowaniu vendored/tests; mocne przypadki
  to m.in. `tools/audit/index_stack.py`, `tools/sync-capabilities.py`,
  `tools/verify/spotify-oauth-grant.{py,sh}`, `scripts/coverage-audit.py`,
  `scripts/hooks/cjk_output_filter.py` (wzmianka tylko w inwentarzu!).
- `tools/capability-graph.py` NIE jest sierotą — wołany przez
  `tools/capability-coverage.py` + `tools/capability-telemetry.py`.

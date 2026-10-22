# Przypadki paritetu — pomiary z 2026-10-17 (AIGON-X)

Wszystkie liczby pochodzą z pomiaru, nie z prozy dokumentacji. Służą jako wzorzec
i jako baseline do porównań przy kolejnych audytach.

## 1. Capability: manifest ↔ katalog runtime

```
manifest enabled:  146
runtime entries:   146
klucze wpisu runtime: description, domain, id, name, title
```

| klucz | zgodne | tylko A | tylko B | wniosek |
|---|---|---|---|---|
| pełna nazwa (`ai:learning`) | 91 | 55 | 53 | artefakt prefiksu, NIE brak wpisów |
| `(domain, name)` | — | 35 | 35 | `domain` w runtime = KATEGORIA (`AI`, `API`, `Architecture`, `Community`…) |
| **`name(lower)` + krotność** | **146** | **0** | **0** | klucz poprawny |

Duplikaty legalne: `reasoning` (kernel + ai), `learning` (kernel + ai) → 146 wpisów,
144 unikalne nazwy. Bramka `capability-key-parity` (GATE-239) porównuje `Counter`.

## 2. Cron: `cron.yaml` ↔ ledger przebiegów

- `cron.yaml`: 389 wpisów; **8 nazw z duplikatami** (42 nadmiarowe wpisy),
  `aigon-run-traced` ×11, `pzl-failover` ×2, `leonardo-keepfull` ×2.
- Skutek złego klucza (`job`): 11 identycznych findingów FAIL dla tej samej nazwy.
- Klucz poprawny: `cron:<job>@<schedule>`.

Semantyka kodów w ledgerze (append-only `cron-last.ndjson`):
`TIMEOUT→124` (FAIL), `QUEUED_COALESCED|SKIP→75` (WARN/DEFERRED), reszta = RC.
Backfill z `cron-run.log*` (z `.gz`) jest dozwolony — import zmierzonych przebiegów;
**nigdy nie wymyślaj rc**.

Rotacja logu: bez archiwów `.gz` liczba „zmierzonych" zadań skakała 71 → 22.

## 3. Bramki: graf ↔ hooks ∪ cron ∪ CI

Trzy defekty metryki w `nexus-graph.py` (wszystkie naprawione):

1. hooks.yaml odwołuje się **slugiem** (`gate-reachability`), a graf mapował po
   `name` (`Registry==Implemented==Wired==Executed`) → ~140 fałszywych sierot;
2. liczono wyłącznie oś hooks — cron i CI (`verify.sh`) były niewidoczne;
3. brak mapy `slug → gate_id` dla komend cron.

Wynik: **150 → 7** bramek bez triggera (6 modułów CI-only + 1 nowa), krawędzie
grafu 89 → 248. Baseline ratchetu zabetonowany na 7.

## 4. Skille: katalog ↔ manifest ↔ graf

| populacja | wartość |
|---|---|
| `SKILL.md` rekurencyjnie | 2919 |
| `skills.manifest` | 2894 |
| węzły `skill` w `decision-graph` | 2883 |
| bez kategorii w `skill-graph.yaml` | 98 |

Test świeżości grafu porównywał `skill_files` (rekurencyjnie) z `os.listdir`
(top-level) → 5 vendored skilli różnicy → fałszywy FAIL na poprawnym grafie.
Poprawka: liczyć tę samą populację (walk rekurencyjny).

**Churn:** w minutach liczba rosła 2914 → 2918 (inni agenci dodają skille).
Reguła: skill + regeneracja grafu w JEDNEJ zmianie, inaczej bramka `context-budget`
flapuje. Martwy wpis manifestu (`hypervisor-principal` = bundle bez top-level
`SKILL.md`) usunięty.

## 5. Referencje do plików w treści skilli

Skan 2919 `SKILL.md`, wzorzec `(scripts|tools|config|runtime|products)/…\.(sh|py|yaml|yml|json|rs)`:

| klasa | unikalne | wystąpienia | akcja |
|---|---|---|---|
| A — plik istnieje pod inną ścieżką | 123 | 392 | przepisz **tylko gdy cel istnieje** |
| B — nie ma nigdzie | 373 | 513 | **nie fabrykuj**; decyzja właściciela treści |

Batch-rewrite A: `runtime/src/* → runtime/crates/aigon-runtime/src/*` —
**282 referencje w 152 skillach**, 167 pominięto (brak celu).
Największy dług B: `scripts/check_output.py` ×64 (nie istnieje w repo, archiwum ani
pobranych) — dowód, że importowany zestaw skilli nie przyniósł swojego helpera.

## 6. Sekrety: repo `.env` ↔ env procesu

| warstwa | wynik |
|---|---|
| `<workspace>/.env` | **0 / 30** endpointów z kluczem |
| env kontenera (148 zmiennych) ∪ `core/.env` | **16 / 30** (`+13` bez potrzeby klucza) |
| rozjazd nazwy | 1: `AIGON_RUNTIME_SHARED_SECRET` w configu vs `RUNTIME_SHARED_SECRET` w kontenerze |

Klasa: `CONFIGURATION_GAP` (alias), nie brak sekretu.

## 7. Ratchet i selftest — zmierzona niestabilność

GATE-229 dawał na przemian `1/4` i `4/4`, bo baseline (cron health 77,1%) był starszy
niż live (76,2%) → test T1 „realny kanon" zwracał rc=1 (regresja zdrowia).
Po przeliczeniu baseline na aktualny pomiar: **3 przebiegi z rzędu 4/4**.

Wniosek: ratchet bez odświeżania po legalnej zmianie stanu produkuje
nondeterministyczny selftest — a to podważa zaufanie do bramki.

## 8. Wzorzec bramki (do skopiowania)

```bash
# 1. skrypt: 0=PASS, 1=FAIL, 2=WARN (źródło niedostępne -> NIGDY zielono)
# 2. --selftest: wstrzyknij defekt, udowodnij wykrycie (pełny skan, nie top-20)
# 3. ratchet: config/canonical/<x>-baseline.json (tylko w dół)
# 4. rejestracja: gate-registry -> hooks(trigger) -> decision-graph -> reachability
```

Czas docelowy: **< 10 s** (GATE-238: 7,8 s na 2919 skillach).

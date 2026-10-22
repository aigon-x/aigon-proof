---
name: coverage-metric-integrity
description: >-
  Projektuj i audytuj metryki POKRYCIA i ZDROWIA tak, żeby „100%" było osiągalne
  i uczciwe. Użyj, gdy budujesz albo naprawiasz metrykę pokrycia (audyt, dashboard,
  bramka, raport „X% monitorowane"), gdy „100% pokrycia" okazuje się nieosiągalne
  z definicji, gdy czerwień znika przez zmianę mianownika, albo gdy licznik
  w API/health wygląda na pomiar, a jest literałem. Zawiera rozstrzygnięcia:
  coverage ≠ health, metryka-z-literału, producent przed „brak dowodu",
  mianownik bez śmieci, ratchet z progiem szumu, EXEMPT z podstawą i terminem.
version: 1.0.0
author: Sniegul (AIGON-X)
license: MIT
metadata:
  hermes:
    tags: [metrics, coverage, health, audit, false-green, gates, observability]
    related_skills:
      - runtime-health-graph-audit
      - health-api-truth-audit
      - false-green-elimination
      - gate-layer-audit
      - runtime-observability-audit
---


# Integralność metryki pokrycia (coverage metric integrity)

## Overview

Metryka pokrycia jest narzędziem, które łatwo samo siebie oszukać. Ten skill zbiera
siedem rozstrzygnięć, każdy zmierzony na żywym systemie (AIGON-X, 2026-10-17),
które decydują o tym, czy „100% pokrycia" znaczy „wszystko zmierzone", czy
„przemalowałem czerwień na szaro".

Punkt wyjścia: audyt runtime raportował 76% pokrycia i 924 elementy UNKNOWN.
Po zastosowaniu tych reguł: **coverage 100%** (4228 elementów), **health 94.2%**,
155 realnych FAIL nadal widocznych, CERTIFIED=False.

## When to Use

- budujesz/naprawiasz metrykę „ile procent systemu jest monitorowane";
- „100% pokrycia" jest nieosiągalne mimo domykania luk;
- czerwień znika, bo zmienił się mianownik, próg albo definicja statusu;
- podejrzewasz, że licznik w `/health`/`/metrics` jest deklaracją, nie pomiarem;
- audyt ogłasza „brak dowodu", a w systemie ktoś ten dowód produkuje;
- ustalasz ratchet/baseline, żeby metryka nie fałszowała w obie strony.

Nie zastępuje procedury pomiaru konkretnego systemu — tej szukaj w
`runtime-health-graph-audit` (12 osi, klasy dowodu, bramka). Ten skill opisuje
JAK ZBUDOWANA MA BYĆ MIARA, tamten — JAK ZMIERZYĆ SYSTEM.

## Reguła 1 — POKRYCIE ≠ ZDROWIE (napraw miarę, zanim naprawisz system)

Jeśli `coverage = PASS / declared`, to każda czerwień **zmniejsza pokrycie**.
Skutek: 100% da się osiągnąć tylko przy zerze FAIL — czyli przez przemalowanie
czerwieni, dokładnie to, czemu audyt ma zapobiegać.

```python
coverage = (observed + EXEMPT_z_podstawa) / declared     # czy wszystko ZMIERZONE
health   = (PASS + EXEMPT) / judged                       # czy zmierzone ZDROWE
CERTIFIED = (coverage == 1.0) and (fail_count == 0)
```

Test odróżniający: **podnieś liczbę FAIL o 1** (albo dodaj element, który na pewno
padnie). Jeśli pokrycie spada — metryka jest źle zbudowana.

## Reguła 2 — METRYKA Z LITERAŁU (najgroźniejsza fałszywa zieleń)

Pole wygląda jak pomiar, a jest stałą w kodzie. Zmierzone: `/api/v1/self/components`
podawał `invocation_count: 0` i `pipeline_edges: 0` dla 46 komponentów **z literału**
(`api.rs:8153`), podczas gdy kernele liczyły to samo pole z `ticks_total`.

Detekcja (dwie komendy, bez zgadywania):

```bash
grep -n '"invocation_count"' <api.rs>     # obok 0u64 / 0 => literał, nie pomiar
```

```python
# dwa pomiary w odstępie 20 s; jeśli licznik nie drgnął na ŻADNYM elemencie,
# to nie „brak ruchu" — to brak instrumentacji
a = sample(); time.sleep(20); b = sample()
print(sum(1 for n in b if b[n]['invocation_count'] > a[n]['invocation_count']), "/", len(b))
# zmierzone: 0/46
```

Status w raporcie: `FAIL` + klasa dowodu `REAL_PROBE` („zmierzono, że nic nie
raportuje"), **nie** `UNKNOWN`. UNKNOWN ukrywa defekt; FAIL daje mu właściciela.

## Reguła 3 — ZANIM ogłosisz „brak dowodu", poszukaj PRODUCENTA

Zmierzone: audyt ogłosił „229 bramek bez dowodu przebiegu", a `hook-runner.sh:391-397`
od dawna pisał `aigon_gate_last_status{gate,trigger}` do textfile. Po podłączeniu:
220/229 zmierzonych, 42 realne FAIL. Był to **defekt miernika**, nie systemu.

Kolejność (30 s):

```bash
ls /var/lib/node_exporter/textfile_collector/ | head -30
grep -c '<nazwa_metryki>' /var/lib/node_exporter/textfile_collector/*.prom
```

Ten sam wzorzec poza monitoringiem: szybkie udane przebiegi cronów (<60 s) często
NIE logują się wcale, a log rotuje co godziny — **brak wpisu w logu ≠ „nie działał"**.
Wtedy potrzebny trwały ledger (append-only NDJSON, `flock -n`, cap rozmiaru,
zapis w `|| true`, RC bez zmian), a decyzję o braku podejmuj po HARMONOGRAMIE:
do 2 okresów = EXEMPT z terminem, po 2 okresach = FAIL.

## Reguła 4 — MIANOWNIK BEZ ŚMIECI

Trzy zmierzone zanieczyszczenia mianownika (każde zawyża „brak pomiaru"):

| śmieć | objaw | poprawka |
|---|---|---|
| drift (element żyje poza SSOT) | `observed > declared`, evidence >100% | licz osobno, nie wchodzi do mianownika |
| kontener katalogów zagnieżdżonych (`anthropic-skills/`, `_archiwum/`) | 62 „skille" bez węzła w grafie | licz tylko katalogi z `SKILL.md` |
| duplikat definicji w pliku źródłowym | ta sama trasa/element liczona 2× | dedup po kluczu (metoda+ścieżka), nie po liczbie wystąpień |

## Reguła 5 — RATCHET Z PROGIEM SZUMU (inaczej czerwienieje na własnym szumie)

Dwie zmierzone pułapki:

1. **Mianownik się rusza** (nowy skill/usługa/endpoint). Tolerancja:
   `tol = min(0.02, max(0.005, 2 / declared))` — dwa elementy przeliczone na udział.
2. **Przejściowy timeout sondy** (2 z 290 = 0.7 pp) wygląda jak regresja.
   Porównuj coverage TYLKO gdy `evidence` nie spadło; inaczej „nie orzeka się
   bez pomiaru" — zapisz `WARN: pomiar niekompletny`, nie REGRESJĘ.

Baseline jest **per kontekst** (per węzeł / per środowisko). Baseline zmierzony na
jednym hoście nie opisuje drugiego — tam progi wyłączamy i raportujemy sam STAN.

## Reguła 6 — EXEMPT MUSI MIEĆ PODSTAWĘ I TERMIN

EXEMPT (pominięcie zaliczone do pokrycia) jest dozwolony wyłącznie z JAWNYM źródłem:

| podstawa | przykład |
|---|---|
| kanon architektury | `expected_down: true`, `enabled: false`, `kernel_expected_degraded` |
| niemożliwość sondy | trasa z `{param}` (brak identyfikatora), cross-node port dropowany przez firewall |
| inny runner | bramka `tools/verify/**` — seria powstaje w CI, nie w hook-runnerze |
| polityka read-only | GET o skutkach ubocznych (`/api/v1/admin/kill`) w `probe_policy.deny_get` |
| **termin** | „oczekuje pierwszego przebiegu po wdrożeniu ledgera" — z datą graniczną |

EXEMPT bez terminu staje się wiecznym ukrywaniem czerwieni. Dług (`debt[]`) wymaga
`owner` + `review_by`; po dacie wygasa i bramka znów czerwienieje.

## Reguła 7 — WERDYKT ≠ CERTYFIKACJA

Rozdziel komunikaty (inaczej operator czyta „PASS" jako „wszystko zdrowe"):

| pole | znaczenie |
|---|---|
| `verdict` przebiegu | PASS / PARTIAL / FAIL (czy pomiar się udał) |
| `certified` | czy cel osiągnięty (coverage 1.0 + zero FAIL) |
| `health_ratio` | ile ze zmierzonych jest zdrowych |

Kontrakt bramki: `0=PASS, 1=FAIL, 2=PARTIAL/WARN, 75=DEFERRED`.
`rc=2` to nie porażka — to „system żyje, ale ma elementy bez pomiaru / czerwienie".

## Anty-wzorce (każdy zmierzony jako realny błąd)

1. `coverage = PASS/declared` — czerwień zmniejsza pokrycie.
2. Budżet sondy < czas odpowiedzi (budżet 5 s vs 8,5 s) → fałszywy FAIL.
3. Port otwarty = zdrowie; HTTP 200 = dowód działania funkcji.
4. Pusty mianownik raportowany jako 100% (ma być `NOT_ESTABLISHED`).
5. Brak wpisu w logu = „nie działa" (bez sprawdzenia harmonogramu i rotacji).
6. Próg bez źródła w kanonie podnoszony „żeby było zielono".
7. EXEMPT bez podstawy, żeby domknąć 100%.
8. Self-report agenta jako dowód stanu.

## Verification checklist

- [ ] dodanie 1 FAIL **nie** zmienia `coverage` (zmienia `health`) — test odwrotny
- [ ] pusty mianownik → `NOT_ESTABLISHED`, nigdy 100%
- [ ] każdy `UNKNOWN` ma sondę do wykonania albo jawne „dlaczego nie"
- [ ] każdy EXEMPT ma podstawę (plik:linia / kanon) i — jeśli czasowy — termin
- [ ] próg szumu zdefiniowany liczbowo i uzasadniony mianownikiem
- [ ] baseline per kontekst; brak porównań między środowiskami
- [ ] zanim ogłoszono „brak dowodu": sprawdzono `textfile_collector` i logi źródłowe
- [ ] raport pokazuje coverage ORAZ health ORAZ listę FAIL z właścicielami

## Support files

- `references/reaching-100-percent-coverage.md` — playbook: 6 konkretnych domknięć
  (endpoints, engines, cron-ledger, gates, providers, skills) z komendami i liczbami
  PRZED/PO, oraz lista tego, co po 100% pokrycia zostaje czerwone.

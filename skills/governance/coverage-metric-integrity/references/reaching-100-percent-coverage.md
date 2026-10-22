# Playbook: z 76% na 100% pokrycia (zmierzony 2026-10-17, AIGON-X runtime)

Stan wejściowy: 4209 elementów, 76.4% „pokrycia", 924 UNKNOWN, 12 FAIL.
Stan wyjściowy: 4228 elementów, **coverage 100%**, **health 94.2%**,
155 FAIL / 89 WARN / 0 UNKNOWN, CERTIFIED=False (bo są realne czerwienie).

## 0. Najpierw miara, potem system

Patrz Reguła 1 w SKILL.md. Dopóki `coverage = PASS/declared`, 100% jest osiągalne
tylko przy zerze FAIL — czyli przez przemalowanie czerwieni. Po rozdzieleniu
`coverage` i `health` 100% staje się jednocześnie osiągalne i uczciwe.

## 1. endpoints (227 → 0 UNKNOWN)

Wcześniej sondowany ręczny podzbiór 28 tras (9.9% evidence). Zamiast listy ręcznej:
parsuj źródło tras i klasyfikuj KAŻDĄ.

| klasa | status | podstawa |
|---|---|---|
| GET bez parametru, poza denylistą | REAL_PROBE (HTTP) | sonda |
| GET z `{param}` | EXEMPT | nie da się sondować bez identyfikatora |
| GET w `probe_policy.deny_get` (np. `/api/v1/admin/kill`) | EXEMPT | polityka read-only w SSOT |
| POST/PUT/DELETE/PATCH | EXEMPT | audyt read-only nie mutuje |

Zmierzone: 290 par metoda×ścieżka (179 GET), 153 sondy → **150 PASS**, 1 FAIL
(`/api/v1/registry/entries` = 503 „TheoryRegistry not configured" — realna luka backendu),
0 UNKNOWN.

**Parser tras:** licz WSZYSTKIE wywołania metod na linii `.route(...)`, nie tylko
pierwszą — trasy łańcuchowe `.get(a).post(b)` inaczej giną (282 zamiast 290 par).

**Budżet sondy >= czas odpowiedzi:** 40 s dla `/api/v1/mesh*`, `/api/v1/graph*`,
`/api/v1/evidence*` (mesh odpowiada ~8,5 s); 30 s dla `/api/v1/self*`; 10 s reszta.
Budżet 5 s dał 6 fałszywych FAIL. Timeout => `WARN: nie zmierzono w budżecie`, nie FAIL.

## 2. engines (46 → 0 UNKNOWN): „brak ruchu" bywa literałem

Dwa pomiary activity w odstępie 20 s: **0/46** silników zmieniło licznik.
`grep '"invocation_count"' api.rs` → obok `0u64` ⇒ metryka jest deklaracją,
nie pomiarem. Status `FAIL` + `REAL_PROBE` („zmierzono brak instrumentacji"),
nie `UNKNOWN`. Właściciel: runtime (wymaga zmiany w binarce).

## 3. cron (243 → 0 UNKNOWN): log nie jest dowodem, ledger jest

Dwie przyczyny po stronie miernika:
1. szybkie udane przebiegi (<60 s) nie logują się wcale;
2. log rotuje co ~12 h — zadania dzienne/tygodniowe wypadają z okna.

Naprawa: `_ledger()` w `cron-run.sh` → `/var/lib/aigon/cron-last.ndjson`
(append-only, `flock -n 9`, cap 5 MB → rotate do 2000 linii, zapis `|| true`,
**RC bez zmian**). Backfill z `cron-run.log*` dozwolony (import ZMIERZONYCH rc).

Decyzja o braku: `cron_period_seconds(schedule)`; do 2 okresów → `EXEMPT` z terminem,
po 2 okresach → `FAIL`. Zmierzone: 178 PASS / 66 FAIL / 9 WARN / 139 EXEMPT, 0 UNKNOWN.

## 4. gates (12 UNKNOWN): producent istniał, miernik go nie czytał

`hook-runner.sh:391-397` pisze `aigon_gate_last_status{gate,trigger}` do
`textfile_collector/aigon-hook-gates-<trigger>.prom`. Po podłączeniu: 220/229
zmierzonych, 42 FAIL, 14 WARN, 3 STALE.

Dwa wyjątki z JAWNĄ podstawą:
- `tools/verify/**` → EXEMPT „runner CI/verify.sh" (seria nie powstaje z definicji);
- bramka z rejestru nieobecna w `hooks.yaml` ANI `cron.yaml` → **FAIL spięcia**
  (nie może się odpalać), nie UNKNOWN. Zmierzone: 3 takie, wszystkie `blocking=true`.

## 5. providers (11 UNKNOWN): sonda osiągalności

`config/providers.yaml:router_endpoints` ma `base_url`, `api_key_env`, `kind`.
Sonda: `GET {base_url}/models` (openai) albo `/api/tags` (ollama), 8 s.
2xx → PASS (osiągalny, brak wywołań w instancji); 401/403/429 → WARN (host żyje,
auth/limit); timeout/5xx → FAIL; brak `base_url` → EXEMPT („wire przez router").
Zmierzone: 13 PASS / 3 WARN / 1 FAIL / 10 EXEMPT.

## 6. skills (62 WARN): kontener to nie skill

`skills/shared/{anthropic-skills,_archiwum,superpowers,…}` to katalogi vendored bez
`SKILL.md` w korzeniu — poza mianownikiem. Brak węzła w grafie decyzyjnym dla
prawdziwego skilla = zmierzony `WARN` (`evidence=EXISTENCE`), nie „brak pomiaru".

## 7. Weryfikacja końcowa (5 komend)

```bash
python3 -m py_compile <skrypt audytu>
bash -n <bramka> <wrapper cron>
<bramka>                     # rc=2 PARTIAL, coverage=1.0
<bramka> --selftest          # 4/4 — dowód negatywny (progi niemożliwe, brak SSOT)
<npm run test | make test>   # kanoniczny zestaw repo
```

`rc=2` NIE jest porażką — to kontrakt PARTIAL. PASS jest nieosiągalny, dopóki
`health < 100%`, i właśnie o to chodzi.

## 8. Co zostało czerwone po osiągnięciu 100% pokrycia

46 silników bez instrumentacji (runtime) · 63 crony FAIL (platform-ops) ·
44 bramki FAIL + 3 bez triggera (platform-ops) · 1 endpoint 503 (runtime) ·
59 skilli poza grafem (knowledge) · 1 provider nieosiągalny (platform-ops).

**100% pokrycia ≠ 100% zdrowia.** Drugie wymaga napraw, nie pomiarów — i to jest
poprawny podział pracy: audyt dowozi pomiar, naprawy mają właścicieli.

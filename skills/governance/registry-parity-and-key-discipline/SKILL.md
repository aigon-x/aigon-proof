---
name: registry-parity-and-key-discipline
description: >-
  Porównywanie DWÓCH rejestrów tej samej prawdy (manifest↔runtime, cron.yaml↔ledger,
  gate-registry↔hooks, skills↔decision-graph, sekrety↔env procesu) bez fałszywych luk.
  Uczy ustalać KLUCZ (nazwa/krotność/prefiks/dyskryminator) i WARSTWĘ pomiaru ZANIM
  ogłosisz „brakuje N elementów". Zawiera wzorzec bramki paritetu z ratchetem i
  dowodem negatywnym (wstrzyknięty defekt MUSI zostać wykryty), procedurę odświeżania
  baseline po legalnej zmianie stanu oraz klasy błędów zmierzone w AIGON-X.
  Użyj, gdy: „ile capability brakuje", „czego nie ma w grafie", „dlaczego audyt
  pokazuje sieroty", „porównaj manifest z runtime", „parity", „coverage spadło",
  „bramka czerwienieje bez powodu", „skill wskazuje nieistniejący plik".
version: 1.0.0
author: Sniegul (AIGON-X)
license: MIT
metadata:
  hermes:
    tags: [audit, parity, registry, measurement, gates, ratchet, evidence]
    related_skills:
      - measurement-truth-discipline
      - runtime-health-graph-audit
      - gate-layer-audit
      - encyclopedia-capability-coverage-audit
      - false-green-elimination
---


# Paritet rejestrów i dyscyplina klucza

## Po co to istnieje

W audycie AIGON-X 2026-10-17 **pięć razy** ogłoszono lukę, której nie było —
za każdym razem dlatego, że porównywano dwa rejestry **złym kluczem albo w złej
warstwie**. Każdy taki „brak" kosztował pracę naprawczą nad czymś, co działa.

> **Reguła nadrzędna:** zanim powiesz „brakuje N elementów", wypisz klucze obu stron
> i policz je `Counter`-em. Różnica zbiorów bez wypisanych kluczy to nie pomiar,
> to zgadywanie.

## Krok 0 — ustal klucz (zanim porównasz)

| pytanie | po co |
|---|---|
| Czym jest JEDEN obiekt po każdej stronie? | nazwa? id? krotka? |
| Czy nazwa jest unikalna? | policz `Counter`; duplikaty to nie błąd, to kontrakt |
| Czy prefiks jest częścią nazwy? | `backend:nazwa` vs `nazwa` — odetnij spójnie |
| Czy pole „kategoria" nie udaje klucza? | `domain` w runtime bywał KATEGORIĄ (`AI`, `API`) |
| Co dyskryminuje duplikaty? | `job@schedule`, `(domain, name)`, `gate_id` |

**Zawsze porównuj KROTNOŚĆ, nie zbiór** (`Counter`, nie `set`). Dwa wpisy o tej samej
nazwie w różnych domenach są legalne (`reasoning`: kernel + ai).

## Krok 1 — ustal warstwę pomiaru (druga pułapka)

Sekret/kod/konfigurację mierz w warstwie, która ją **konsumuje**, nie tam, gdzie
leży wygodny plik:

| obiekt | zła warstwa | właściwa warstwa |
|---|---|---|
| sekrety runtime | `<workspace>/.env` (0/30!) | env KONTENERA (148 zmiennych) + `core/.env` → 16/30 |
| capability | manifest YAML | `GET /api/v1/capabilities` (żywy katalog) |
| bramki | `gate-registry.yaml` | textfile `aigon_gate_last_status` z `hook-runner` |
| cron | `cron.yaml` | ledger przebiegów `cron-last.ndjson` + logi z rotacją |

Zmierzone 2026-10-17: kontrola „klucz w repo .env" dała **0/30** i wyglądała na
katastrofę; po przejściu na env kontenera — 16/30 + 13 bez potrzeby klucza + **1 realny
rozjazd aliasu** (`AIGON_RUNTIME_SHARED_SECRET` vs `RUNTIME_SHARED_SECRET`).

## Krok 2 — porównaj i NAZWIJ różnicę

Wypisz: `only_left`, `only_right`, `count_mismatch`. Dopiero potem klasyfikuj.
Jeśli różnica jest **strukturalna** (prefiks, kategoria, zakres skanowania) — popraw
klucz i zmierz ponownie, zanim cokolwiek naprawisz.

Tabela przypadków (wszystkie zmierzone w AIGON-X, szczegóły w
`references/parity-cases-2026-10.md`):

| rejestr A ↔ B | klucz błędny | klucz poprawny | efekt błędu |
|---|---|---|---|
| manifest capability ↔ runtime | pełna nazwa `ai:learning` | `name(lower)` + krotność | 53+55 fałszywych sierot |
| to samo, 2. próba | `(domain, name)` | jak wyżej | 35 fałszywych (`domain`=kategoria) |
| `cron.yaml` ↔ ledger | nazwa zadania | `job@schedule` | 11 identycznych FAIL-i dla `aigon-run-traced` |
| gate-registry ↔ hooks | nazwa opisowa bramki | **slug komendy** | „150 bramek bez triggera" → realnie **7** |
| skills ↔ decision-graph | `os.listdir` (top-level) | rekurencyjny `SKILL.md` | 5 vendored skilli różnicy |

## Krok 3 — bramka paritetu (defect → gate)

Wzorzec, który działa (GATE-238/239 w AIGON-X):

1. **skrypt** `scripts/<x>-parity.py` — kontrakt `0=PASS`, `1=FAIL`, `2=WARN`
   (runtime niedostępny = **WARN, nigdy zielono**);
2. **ratchet** w `config/canonical/<x>-baseline.json` — wolno TYLKO zmniejszać;
3. **dowód negatywny** w `--selftest`: wstrzyknij defekt i udowodnij, że skan go
   widzi. Pułapka: liczenie z „top-20 findings" nie widzi wstrzyknięcia o krotności 1
   → potrzebny tryb pełnego skanu (`--grep`). Inaczej „selftest PASS" dowodzi tylko,
   że skrypt się uruchomił;
4. **rejestracja jedną zmianą**: `gate-registry.yaml` → `hooks.yaml` (trigger) →
   `decision-graph` → `gate-reachability` PASS;
5. **czas przebiegu < 10 s** — wtedy może iść w pre-push, nie tylko w cykl.

## Krok 4 — baseline po legalnej zmianie stanu

Ratchet porównuje z baseline. Jeśli stan legalnie się zmienił (nowe zadania cron po
wprowadzeniu ledgera, nowe skille od innych agentów), **baseline jest starszy niż
rzeczywistość** i bramka zaczyna oblewać własny `--selftest` (zmierzone: GATE-229
na przemian 1/4 i 4/4, bo cron health 76,2% < baseline 77,1%).

Procedura: zmierz → przelicz baseline na aktualny pomiar → uruchom `--selftest`
**trzy razy** i pokaż, że jest stabilny. Baseline to podłoga, nie życzenie.

## Krok 5 — „brak przebiegu" i „brak pomiaru" to różne statusy

- **brak przebiegu po N okresach harmonogramu** = FAKT ZMIERZONY → `observed=True`,
  `FAIL`, `evidence=REAL_PROBE`. Pokrycie nie może na tym spadać (zmierzone:
  1.0 → 0.9995 przez pomyłkę).
- **brak jakiegokolwiek kanału pomiaru** (np. gola komenda poza wrapperem) =
  `EXEMPT` z jawną podstawą albo `UNKNOWN` — nigdy `PASS`.

## Krok 6 — naprawa referencji w treści (skille, runbooki)

Gdy skan wykaże referencje do nieistniejących plików, dziel je na klasy:

| klasa | znaczenie | akcja |
|---|---|---|
| A | plik istnieje pod inną ścieżką (stale path po restrukturyzacji) | przepisz **tylko gdy cel istnieje**; policz i zaraportuj |
| B | nie ma go nigdzie w przeskanowanych drzewach | **NIE fabrykuj narzędzia** — decyzja właściciela treści (odtworzyć / przepisać / oznaczyć jako historyczne) |

Zmierzone: 2919 skilli, 496 referencji (853 wystąpienia), 545 skilli (19%) z błędem.
Batch-rewrite klasy A naprawił **282 referencje w 152 skillach** (167 pominięto, bo cel
nie istniał — zostały jako dług B pod ratchetem).

## Pitfalls

1. **Zbiór zamiast krotności** gubi legalne duplikaty i tworzy fałszywe „brakuje 2".
2. **`domain`/`category` jako część klucza** — w jednym rejestrze to backend, w drugim
   kategoria. Sprawdź, co realnie zawiera pole, na 3 przykładach.
3. **Porównanie „nazwa opisowa" vs „slug"** — w grafach bramek trigger wskazuje slug
   komendy, nie `name`. Mapowanie po nazwie robi 140 fałszywych sierot.
4. **Zakres skanowania** (`top-level` vs rekurencyjnie) to inna populacja, nie inny
   stan systemu.
5. **Selftest bez wstrzyknięcia** = bramka może być ślepa i nadal „PASS".
6. **Baseline nieodświeżony** po legalnej zmianie = nondeterministyczny selftest.
7. **Brak pomiaru w warstwie konsumpcji** → 0/N i panika; sprawdź env procesu,
   textfile producenta, żywy endpoint.
8. **Nie zmieniaj progu, żeby „wyszło"** — popraw klucz, warstwę albo rejestr.

## Verification Checklist

- [ ] klucze obu stron wypisane; `Counter` (krotność), nie `set`
- [ ] różnica strukturalna odrzucona ZANIM ogłoszono lukę
- [ ] warstwa pomiaru = warstwa konsumpcji
- [ ] bramka: 0/1/2, WARN gdy źródło niedostępne, ratchet, **selftest z wstrzyknięciem**
- [ ] rejestracja: registry → hooks → graf → reachability PASS
- [ ] baseline odświeżony po legalnej zmianie; selftest 3× stabilny
- [ ] klasa A przepisana tylko przy istniejącym celu; klasa B NIE fabrykowana

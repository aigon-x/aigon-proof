# Integralność GENEROWANEGO rejestru bramek (SSOT → generator → meta-bramka)

Zmierzone 2026-10-15 przy budowie rejestru bramek ze spec SSOT
(`config/family-spec.yaml` → `tools/inorg-gen.py` → `gates/gate-registry.yaml` +
`tools/gates/commands.sh`). Klasa: rejestr/wpisy generowane z jednego źródła prawdy.

## Wzorzec architektoniczny — 4 elementy (bez żadnego = teatr)

1. **SSOT deklaratywny** — JEDEN plik (podmioty, komponenty, rodzaje bramek).
2. **Generator** — SSOT → artefakty (rejestr, tasklisty per podmiot, mapa komend).
   Artefakty oznaczaj „GENEROWANE przez <gen> — nie edytuj ręcznie".
3. **Konsument** — RUNNER, który artefakt FAKTYCZNIE wykonuje (nie tylko parsuje).
   Bez konsumenta rejestr jest dekoracją: zmierzone — 5 plików tasklist leżało ~2 tygodnie
   BEZ żadnego konsumenta w repo (czysty teatr; treść dodatkowo kłamała, np. „build: unity"
   dla projektu JS).
4. **Meta-bramka** — `registry == implemented == wired (+ unique)`. Sprawdza SAM rejestr.

## Defekt 1 — generator NIEDETERMINISTYCZNY (drift, którego nie da się domknąć)

Iteracja po SECIE (np. `{g["gate_id"] for ...}`) ma kolejność zależną od losowego
hasha stringów (`PYTHONHASHSEED`). Ten sam input → inny output → `--check` ZAWSZE zgłasza
drift → generator „nigdy nie zbiega", nie wiadomo, czy artefakt odpowiada SSOT.
**FIX:** `sorted({...})` przy każdej iteracji po secie. **Dowód:** `gen --check` musi
kończyć exit 0 („brak driftu") — to test idempotencji generatora.

## Defekt 2 — `gate_id` NIEUNIKALNY (duplikat prawdy w rejestrze)

Rejestr powstawał per ZADANIE, a kilka zadań dzieliło jeden `gate_id`:
- 3 fazy (build/test/lint) jednego komponentu → 3 wpisy z tym samym id;
- 5 zadań analitycznych jednego podmiotu → 5 wpisów `...-ANALYSIS`.
Zmierzone: `587 wpisów / 540 unikalnych / 47 duplikatów` — meta-bramka tego NIE łapała,
bo sprawdzała tylko istnienie pliku komendy. **FIX:** id musi nieść dyskryminator
(workdir dla komponentu; numer/faza dla zadania), a meta-bramka MUSI liczyć unikalność:
`len(ids) == len(set(ids))`, inaczej FAIL.

## Reguły meta-bramki (inaczej kłamie)

- `registry == implemented`: każdy wpis ma istniejący plik komendy.
- `wired`: plik komendy ma bit `+x`.
- `unique`: `len(ids) == len(set(ids))` (dodane po defekcie 2).
- **Wykonawca musi znać każdy rodzaj**: gdy wpis `gate_id` nie ma case'a w wykonawcy,
  komenda zwraca `nieznany KIND` (exit 2) — to WYGLĄDA jak FAIL, a jest błędem DEFINICJI.
  Zanim ogłosisz czerwony, sprawdź, czy wykonawca obsługuje dany rodzaj i czy wywołujesz
  WŁAŚCIWEGO wykonawcę (bramka toolchainowa idzie przez `gate-toolchain.sh`, nie
  `gate-project.sh`) — zła komenda = fałszywy alarm.
- **Bramka bez dowodu negatywnego nie istnieje**: sabotaż → FAIL, przywrócenie → PASS.

## Kolejność autorstwa (od SSOT, nigdy odwrotnie)

1. Spec SSOT (deklaracja). 2. Generator (deterministyczny). 3. Rejestr (generowany).
4. Konsument/runner. 5. Meta-bramka (integralność + unikalność). 6. `gen --check` = brak driftu.
Ręcznie pisany rejestr rozjedzie się z SSOT przy pierwszej zmianie — jedno źródło prawdy
znaczy też jedno miejsce edycji.

## Zagnieżdżony „duplikat prawdy" w nazwach plików/katalogów

Ta sama klasa co nieunikalny `gate_id`, ale na systemie plików: katalog o nazwie różniącej
się NIEWIDOCZNYM znakiem (np. dywiz U+2011 `e2 80 91` zamiast ASCII `2d`) tworzy drugi
katalog obok prawdziwego. Zmierzone: `shared/detection‑engine` (U+2011) obok
`shared/detection-engine`. Diagnoza: `ls -b1` / `hexdump -C` na nazwie; autorytet = co
deklaruje manifest (`.gitmodules` / MANIFEST), nie co leży na dysku. Sprzątaj WŁASNE
duplikaty, ale rozstrzygaj po deklaracji, nie po wyglądzie.

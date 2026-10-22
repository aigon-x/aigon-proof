# Detektor ZA SZEROKI: plik poza repo nie może blokować commitów (2026-10-01)

## Objaw (4× w jednej sesji)

Bramka `scripts-wired-check` (pre-commit, `block_on_fail=true`) zatrzymywała commity
**wszystkim**, bo w `scripts/` leżał plik, który nie był częścią repo:

```
FAIL sierota: prompt_index.py [unknown] — NIEZNANE — do decyzji: podpiąć do cron/hooka albo allowlista
FAIL sierota: hermes-mesh-dashboard.sh [unknown] — …
```

Pliki: `prompt_index.py`, `hermes-mesh-dashboard.sh` (untracked) oraz
`binary-integrity-guard.sh`, `resource-governor.py`, `skill-description-trim.py`
(zastagowane `git add`, bez commita) — wszystko praca **równoległej sesji w toku**.

## Rozumowanie, które prowadzi do naprawy

Bramka pilnuje kontraktu „napisane = PODPIĘTE". Ale plik **bez deklaracji w repo nie
może tej deklaracji łamać**. Praca w toku to nie martwy kod. Trzy kategorie zamiast dwóch:

| stan pliku | werdykt |
|---|---|
| w HEAD i nie wpięty | **FAIL** — realny defekt (napisane, nie podpięte) |
| poza HEAD (untracked / staged-only) | **WARN z nazwą** — do decyzji autora |
| wpis w allowliście z uzasadnieniem | WARN |

## Pułapka wykonania: indeks ≠ kontrakt

`git ls-files` czyta **INDEKS**, więc samo `git add` bez commita wyglądało jak
„zadeklarowane w repo" i dawało FAIL. Podstawą musi być **HEAD**:

```python
subprocess.run(["git","-C",root,"ls-tree","-r","HEAD","--name-only","scripts"], …)
```

## Zabezpieczenie PRZECIW FAŁSZYWEJ ZIELENI (obowiązkowe)

Jeśli git nie odpowie (brak repo, błąd), zbiór „tracked" jest pusty — a wtedy
naiwna klasyfikacja wrzuciłaby **WSZYSTKIE** sieroty do WIP i bramka przepuściłaby
martwy kod. Dlatego przeklasyfikowanie wykonuj TYLKO gdy zbiór jest niepusty:

```python
wip = []
if tracked:                      # ← ten warunek jest sednem bezpieczeństwa
    wip = [r for r in unjustified if r["script"] not in tracked]
    unjustified = [r for r in unjustified if r["script"] in tracked]
```

Bonus: `except Exception: tracked = set()` naturalnie wpada w „nie przeklasyfikowuj",
czyli błąd gita degraduje do zachowania POPRZEDNIEGO (fail-closed), a nie do zieleni.

## Weryfikacja zmiany bramki (ad-hoc, bez tworzenia commitów)

Nie da się bezpiecznie zrobić „prawdziwej" sieroty w HEAD na współdzielonym repo.
Weryfikuj więc **predykat** i **skutek**:
* predykat: `'cron-run.sh' in tracked == True` (committed → trafi do FAIL),
  `'skill-description-trim.py' in tracked == False` (staged-only → WIP),
* skutek: bramka `status=PASS`, `orphans_unjustified=0`, `orphans_wip_untracked>0`,
* źródło: `grep -q "if tracked:"` i `grep -q "ls-tree.*HEAD"` — zabezpieczenie i podstawa.

Zawsze też sprawdź, że żadna nazwa z WIP **nie jest** w HEAD
(`git ls-tree -r HEAD --name-only | grep -c <nazwa>` → 0) — to dowód, że zdjąłeś
blokadę tylko z nie-zacommitowanych.

## Wniosek klasowy

Bramka blokująca wszystkich z powodu cudzej pracy w toku to nie „rygor", to **awaria
przepustowości**. Test: zadaj pytanie „czy ten plik jest CZĘŚCIĄ repo?" — jeśli nie,
jego brak wpięcia nie jest niczyim naruszeniem.

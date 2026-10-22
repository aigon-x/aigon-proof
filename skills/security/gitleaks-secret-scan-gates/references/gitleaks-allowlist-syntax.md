# Gitleaks allowlist — składnia regexes i targetRules (zmierzone 2026-09-30, gitleaks 8.30.1)

Kontekst: commit w repo `akceleratory` blokowany przez pre-commit hook gitleaks
z 3 trafieniami `generic-api-key`, wszystkie FAŁSZYWE (fixture testowy z
`api_key: ***` w pliku testu bezpieczeństwa + 2× hash alertu `key=<32hex>` w
raporcie). Dopisanie allowlisty zajęło 7 prób (A–G) — poniżej co NAPRAWDĘ
działa, bo dokumentacja i intuicja mylą.

## Wynik: działająca konfiguracja (gitleaks 8.30.1)

```toml
title = "AIGON-X akceleratory — bramka sekretow"

[extend]
useDefault = true

[[allowlists]]
description = "Falszywe alarmy 2026-09-30 (fixture + hash alertu)."
regexTarget = "match"
regexes = ['''api_key''', '''key=[0-9a-f]{32}''']
```

## Co NIE działa (każde zmierzone osobnym przebiegiem na tym samym staged)

| # | Wariant | Wynik | Wniosek |
|---|---|---|---|
| A | `[[allowlists]]` + `regexTarget="secret"` + `'''^\*\*\*$'''` | 3 leaki | `secret` NIE dopasowuje — mimo że regex jest poprawny (sprawdzony `re.match` w Pythonie) |
| B | `regexTarget="secret"` + `'''hunter2'''` (literal) | 3 leaki | to nie problem escape'ów — `secret` jako target nie działa w ogóle |
| C | `regexTarget="match"` + `'''api_key'''` | 2 leaki | **match DZIAŁA** (zbił 3→2) |
| D | brak `regexTarget` (domyślny) + `'''hunter2'''` | 3 leaki | domyślny nie filtruje |
| E | `regexTarget="match"` + oba `api_key` i `key=[0-9a-f]{32}` | 1 leak | dwie reguły łapią dwie klasy trafień |
| F | `regexTarget="match"` + `'''api_key: \*\*\*'''` | 3 leaki | **escape'y `\*` w match NIE działają** |
| G | `regexTarget="match"` + `'''api_key: ...'''` | 2 leaki | kropki jako wildcard OK, ale łapie za szeroko |
| ✓ | `regexTarget="match"` + `'''api_key'''` + `'''key=[0-9a-f]{32}'''` | **0 leaków** | rozwiązanie |

## Reguły wynikające z pomiaru

1. **`regexTarget = "match"`** — jedyny działający target dla `regexes`.
   `"secret"` (i domyślny) NIE filtrują.
2. **Używaj LITERAŁÓW, nie escape'ów.** `api_key` działa; `api_key: \*\*\*`
   nie. Trzymaj się prostych fragmentów.
3. **`[[allowlists]]` (lista), nie `[allowlist]`** — 8.30.1 to tablica tabel.
   Stary `[allowlist]` z `paths`/`regexes` na tym samym poziomie daje błąd
   parsowania przy mieszaniu, albo jest ignorowany.
4. **`targetRules` NIE pomaga** do zawężania do jednej reguły — nie polegaj na nim.
5. **`regexTarget="line"`** — nie istnieje; gitleaks przyjmuje `match`/`secret`.

## Diagnostyka: jak zobaczyć CO gitleaks dopasował

Domyślnie raport REDAGUJE sekret (`Secret: '***'`, 14 znaków — mylące!).
Pole `Match` pokazuje kontekst, np. `'napi_key: ***\\n'`. Żeby zobaczyć
prawdziwe wartości:

```bash
gitleaks git --staged -c .gitleaks.toml --report-format json \
  --report-path /tmp/leaks.json --redact=0
python3 -c "import json; [print(x['File'], repr(x['Match']), repr(x['Secret'])) for x in json.load(open('/tmp/leaks.json'))]"
```

Drugi podszept: tymczasowo wstaw `printf '[HIT] %s\n' "$out" >&2` w funkcji
`scan()` bramki — pokaże surowe linie trafień bez zgadywania.

## Pułapka: allowlist działa, ale blokada wraca przy następnym pliku

Po dodaniu allowlisty na 2 wzorce, kolejny commit może trafić na **inny**
plik z tym samym problemem. Zanim uznasz, że allowlist „nie działa" — sprawdź
czy nie przybył nowy plik (np. `staged:` w raporcie pokaże inne `File`).
W tej sesji allowlista zamknęła 3 trafienia w jednym pliku, ale osobny commit
odsłonił `PGPASSWORD='...'` w transkrypcie (inny kanał, inny wzorzec).

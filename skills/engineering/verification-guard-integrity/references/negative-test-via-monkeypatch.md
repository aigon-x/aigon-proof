# Test negatywny przez MONKEY-PATCH w pamięci procesu (2026-09-29)

Uzupełnienie `references/negative-tests-and-false-fails.md`. Tam mutuje się
PLIK na dysku (`flip(path, needle, repl)`). Tu mutuje się **stan w pamięci
procesu** — gdy bramka nie czyta jednego pliku, lecz skanuje N katalogów,
a ruszenie ich na dysku jest niedopuszczalne (cudza praca, dane produkcyjne,
współdzielone drzewo).

## Kiedy to jest JEDYNA opcja

Bramka `skill-registry-integrity.py` sprawdza, czy rdzeń (269 skilli) jest
dostarczony do **7 katalogów agentów** (`~/.qwen`, `~/.claude`, `~/.hermes`,
`~/.grok`, `~/.aigon`, `~/.codex`, `~/.dsh`). Żeby udowodnić, że bramka umie
paść, trzeba zmusić ją do zobaczenia agenta BEZ skilli. Warianty:

| wariant | dlaczego odpada |
|---|---|
| skasować skille jednemu agentowi | destrukcyjne, dotyka cudzego środowiska |
| dodać fałszywego agenta do konfiguracji | zmienia stan repo pod commitem |
| **podmienić listę katalogów w pamięci** | ✅ nic nie dotyka dysku |

## Wzorzec

```python
import importlib.util, sys, os, io, contextlib, json

sys.argv = ['g', '--json']                       # moduł czyta argv na starcie
spec = importlib.util.spec_from_file_location('g', '<workspace>/tools/gates/skill-registry-integrity.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)                       # ładowanie; SystemExit łap, gdy jest

os.makedirs('/tmp/hermes-verify-empty', exist_ok=True)   # agent BEZ skilli
m.AGENT_SKILL_DIRS = {"qwen": "/tmp/hermes-verify-empty"}  # mutacja W PAMIĘCI

buf = io.StringIO()
try:
    with contextlib.redirect_stdout(buf):        # bramka pisze na stdout
        m.main()
except SystemExit as e:
    print("EXIT:", e.code)                       # 0=pass, 1=fail

d = json.loads(buf.getvalue())                   # tryb --json = parsowalny werdykt
f = [x for x in d['findings'] if x['check'] == 'rdzen_niedostarczony']
print("VERDICT:", d['verdict'], "| braki:", len(f[0]['brak_u_agentow']) if f else 'BRAK-CHECKU')
```

Zmierzone: `VERDICT: FAIL | wykryte braki: 40`. Bramka **nie jest ślepa** —
dowód obu stron kontraktu:
- stan poprawny → `EXIT=0`, `rdzeń=269 (kompletny=true), wszystkie dostarczone`
- stan zepsuty (agent pusty) → `FAIL`, 40 braków

## Pułapki tego wzorca

**(a) Sygnatura funkcji autorytetu.** `m._skills_core_set()` rzuciło
`TypeError: missing 1 required positional argument: 'cfg'`. Czytaj sygnaturę
PRZED wywołaniem (`grep -n '^def ' <moduł>`), nie zgaduj z nazwy.

**(b) Zmienne globalne czytane na poziomie IMPORTU.** Jeśli bramka robi
`DIRS = load_dirs()` w ciele modułu (nie w `main()`), podmiana po
`exec_module` ZADZIAŁA (bo `main()` czyta `m.AGENT_SKILL_DIRS` w czasie
wykonania), ale gdyby moduł skopiował listę do zmiennej lokalnej w `main()` —
podmiana byłaby bezskuteczna. **Sprawdź, GDZIE bramka czyta listę**: jeśli
w `main()`, patch ma sens; jeśli raz na starcie w zasięgu modułu i `main()`
używa już skopiowanej — mutuj PRZED `exec_module` albo podmień plik wejściowy.

**(c) `--json` jest niezbędny.** Bez trybu maszynowego parsujesz stdout
człowieczy — kruche i podatne na ten sam defekt co „porównywanie literałów".
Bramki powinny mieć `--json`; jeśli nie mają, to luka do zgłoszenia.

**(d) `sys.argv` przed `exec_module`.** Moduły CLI często wołają
`argparse`/`main()` w `if __name__ == '__main__'` — ale część parsuje argv
w ciele. Ustaw argv PRZED ładowaniem.

**(e) Sprzątanie w `/tmp` jest częścią testu.** Po przebiegu
`rm -rf /tmp/hermes-verify-empty` i potwierdź brakiem plików (`ls` zwraca
„Nie ma takiego pliku"). Zostawiony katalog-pułapka to śmieć, który
zatruje następny przebieg.

## Reguła klasy

Bramka, która skanuje WIELE źródeł, ma test negatywny przez **podmianę
jednego ze źródeł w pamięci**, nie przez psucie danych na dysku. Odwrotnie niż
bramka plikowa: tam mutujesz plik i porównujesz `git diff | sha256sum` przed/po;
tu nie mutujesz nic i dowodem jest para
`(EXIT na stanie poprawnym, EXIT na stanie podmienionym)`.

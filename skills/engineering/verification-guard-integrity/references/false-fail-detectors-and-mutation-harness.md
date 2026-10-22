# Fałszywe FAIL-e własnych detektorów + harness testów negatywnych

Sesja 2026-09-28 (`/opt/projects/miki`: gra Roblox/Luau + strona dostawy dla
syna). **Cztery razy z rzędu mój własny detektor zapalił czerwień na POPRAWNYCH
danych** — ani raz nie był to defekt produktu. Klasa jest kosztowna, bo
fałszywy czerwony prowadzi do „naprawiania" dobrego kodu (albo do przepisania
dokumentu, który mówił prawdę).

## 0. Reguła nadrzędna

**Zanim uznasz czerwień za defekt: nazwij ROLE obu porównywanych wartości.**
Nie „czy są równe", ale „czym JEDNA jest wobec DRUGIEJ". Wszystkie cztery
przypadki niżej to porażka tego pytania, nie logiki.

## 1. Cztery zmierzone fałszywe FAIL-e

### (a) Literał wersji wpisany w weryfikator

Weryfikator dostawy sprawdzał `'href="/gra-v17-2037.zip"' in page`. Po
wystawieniu v19 zapalił DWA FAIL-e („NAJNOWSZA to v17", „hash gry == build") —
porównywał **stałą** zamiast tego, co strona faktycznie wskazuje.
Naprawa: bierz wartość ZE ŹRÓDŁA, którego dotyczy twierdzenie:

```python
hero = re.search(r'<a href="/(gra-v\d+-\d+\.zip)"', page).group(1)
naj  = re.search(r'\((v\d+)\) — NAJNOWSZA', page).group(1)
check("NAJNOWSZA dotyczy tego samego pliku co hero", naj in hero)
# dalej: hash licz z pliku wskazanego przez hero, nie z nazwy wpisanej ręcznie
```

### (b) Fraza, którą dokument CYTUJE jako sprostowaną

Detektor żądał braku frazy „NIE MA jeszcze ani jednego pliku dźwiękowego"
(dawna nieprawda o braku plików audio). Nowy CHANGELOG **cytuje** tę frazę,
żeby ją sprostować → detektor uznał POPRAWNY dokument za kłamstwo.
Naprawa: pytaj o SENS, nie o obecność stringa — fraza może wystąpić wyłącznie
w zdaniu, które ją unieważnia.

### (c) Ta sama fraza w wpisie HISTORYCZNYM (konflikt ról w czasie)

Po naprawie (b) detektor nadal czerwienił: fraza żyje w starym wpisie
`WERSJA 0.9.0 (paczka v10)`, gdzie była **prawdziwa w swoim czasie** (wtedy
naprawdę nie było plików audio). Changelog to zapis historii — stary wpis nie
staje się kłamstwem dlatego, że dziś jest inaczej.
Naprawa: ogranicz pomiar do **sekcji bieżącej wersji**:

```python
parts = re.split(r"^WERSJA ", text, flags=re.M)
top = ("WERSJA " + parts[1]) if len(parts) > 1 else ""
```

### (d) Nieaktualna LISTA oczekiwanych plików

Sprawdzenie „repo czyste" whitelistowało wyjścia trwającej fali; jeden plik
(raport audytu) powstał w trakcie przebiegu → FAIL. Reguła dobra, dane
nieaktualne. Naprawa: lista JAWNA i utrzymywana — nigdy „cokolwiek się pojawi"
(to zrobiłoby z detektora tautologię).

## 2. Harness testów negatywnych (`--negative`)

Wymóg: **każdy nowy strażnik mierzony TRZY razy** — zielony PRZED, czerwony po
celowym zepsuciu kodu, zielony po przywróceniu (plus dowód, że plik wrócił
1:1). Trzeci pomiar jest równie ważny jak drugi: dowodzi, że strażnik nie jest
„zawsze czerwony", a mutacja została cofnięta.

```python
NEGATIVE_CASES = [
    # (plik, co podmienić, na co, czym mierzyć, etykieta)
    ("scripts/build.sh", "lua5.1 tests/fastnight.lua", "# CELOWO USUNIETE",
     ["python3", "tests/check_gate_coverage.py"], "zestaw wypadł z bramki"),
    ("src/server/ServerRuntime.lua",
     "\t\tstate.ends = os.clock()\n\t\t\t+ (PhaseMachine.phaseTime(phase) or …)",
     "\t\tstate.ends = os.clock() + (Config.World.PhaseTime[phase] or …)",
     ["lua5.1", "tests/fastnight.lua"], "powrót zdublowanej definicji fazy"),
    ("tests/serverruntime_glue.lua", "spawn = runSpawn,", "spawn = function() end,",
     ["lua5.1", "tests/serverruntime_glue.lua"], "pusty task.spawn (defekt rigu)"),
]

def run_negative():
    for path, needle, repl, guard, label in NEGATIVE_CASES:
        full = os.path.join(ROOT, path); src = open(full, encoding="utf-8").read()
        if needle not in src:
            check("N %s: wzorzec istnieje" % label, False, path); continue
        def run():   return subprocess.run(guard, cwd=ROOT, capture_output=True, text=True)
        def flip(b): open(full, "w", encoding="utf-8").write(
                         src.replace(needle, repl if b else needle, 1))
        before = run(); flip(True); mutated = run(); flip(False); restored = run()
        check("N %s: zielony PRZED" % label,       before.returncode == 0)
        check("N %s: CZERWONY po zepsuciu" % label, mutated.returncode != 0)
        intact = open(full, encoding="utf-8").read() == src
        check("N %s: zielony po przywróceniu (plik 1:1)" % label,
              restored.returncode == 0 and intact)
```

Zmierzone: 9 pomiarów (3 przypadki × 3) → `49 PASS, 0 FAIL`; po dodaniu
kolejnego strażnika `50 PASS`.

**Domknij pętlę na poziomie repo:** mutuj PRAWDZIWE pliki robocze, ale
przywracaj treść, którą sam wczytałeś (nie `git checkout`), porównaj bajty, a
po całym przebiegu sprawdź odcisk drzewa (`git status --porcelain` + `git diff`)
— identyczny przed i po. Inaczej „przywróciłem 1:1" zostaje deklaracją.

## 3. Strażnik pokrycia bramki

Osobna klasa (odwrotność „moduł bez wpięcia"): **strażnik istnieje, ale żaden
runner go nie woła**. Zmierzone: 616-linijkowy zestaw GLUE dla monolitu nie był
w bramce — 3 jego asercje padały niepostrzeżenie. Mechanizm:

* każdy `tests/*.lua` MUSI mieć w skrypcie bramki linię `lua5.1 tests/<plik>`;
* bramka nie może wołać plików nieistniejących (dryf w drugą stronę);
* wyjątki JAWNE z powodem (`harness.lua` = biblioteka atrapy; `*.client.lua` =
  sondy uruchamiane w Studiu, nie pod `lua5.1`) — wyjątek bez powodu to cicha
  dziura;
* ten strażnik pilnuje SAMEJ bramki → uruchamiaj go PIERWSZY.

**Dowód, że nie jest pusty** — podaj temu samemu sprawdzeniu dwa obiekty z
różnych epok i pokaż, że wynik się RÓŻNI (relacja, nie stała):

```
dist/gra-v20-2126.zip -> PASS (WERSJA 0.9.9 … paczka v20)
dist/gra-v19-2116.zip -> FAIL (WERSJA 0.9.0 … paczka v10)   <- tak wyglądał defekt
```

Ogólnie: strażnik RELACJI („pole X opisuje obiekt Y") testuj na parze
(obiekt zgodny, obiekt niezgodny) — inaczej nie odróżnisz strażnika od `True`.

## 4. Wnioski przenośne

- Detektor porównujący **stałą** mierzy stałą. Sięgnij po wartość ze źródła,
  którego dotyczy twierdzenie (strona → jej HTML, paczka → jej ZIP).
- Detektor na **obecność stringa** przegrywa z każdym tekstem, który ten string
  cytuje, prostuje albo opisuje historycznie. Pytaj o sens i o ZAKRES.
- Detektor na **nieaktualnej liście** czerwieni fałszywie — aktualizuj listę,
  ale trzymaj ją jawną (inaczej detektor staje się tautologią).
- Każdy nowy strażnik: zielony → **czerwony po zepsuciu** → zielony po
  przywróceniu. Trzy pomiary, nie jeden.

## 5. Rig testowy, który KŁAMIE o produkcji (Luau/Roblox, ta sama sesja)

Zanim uznasz czerwone asercje za defekt produktu — sprawdź RIG i udowodnij to
A/B (przywróć starą linię produkcyjną: jeśli zestaw pada IDENTYCZNIE, to rig).

- **`task.spawn` jako pusty no-op.** `_G.task = { spawn = function() end }`
  (a komentarz obok obiecywał `flush`, którego w pliku nie było) → ładowanie
  profilu w `PlayerAdded` nigdy nie ruszało → gracz zostawał w `status=LOADING`
  → monolit nie wychodził z `WAITING` → 3 asercje czerwone z powodu RIGU.
  Pułapka ma dwie strony: synchroniczny spawn WIESZA zestaw na produkcyjnej
  pętli `while true do task.wait(...) end` (EXIT=124, pusty stdout).
  Lek: spawn na korutynie + `task.wait` z `coroutine.yield()` pod
  `if coroutine.running() then` (yield poza korutyną rzuca błąd).
- **Nowy `require` w module produkcyjnym wywala WSZYSTKIE rigi**, które mają
  własną tabelę modułów i `assert(modules[name], name)`. Objaw:
  `lua5.1: tests/runtime.lua:392: PhaseMachine` ze stackiem przez
  `src/server/ServerRuntime.lua`. To nie szum — każdy taki rig wymaga wpisu;
  dopisuj moduł PRAWDZIWY (`Harness.useReal`), nigdy atrapę.
- **Zdublowana definicja prawdy = suwak bez wykonawcy.** Moduł trzymający knob
  (`PhaseMachine.phaseTime`) był osiągalny tylko ścieżką referencyjną, a
  produkcja liczyła tę samą wielkość drugi raz wprost z `Config`. Funkcja ma
  konsumenta, konsument ma testy, a knob nie robi nic. Naprawa: jedna definicja
  (eksport + wołanie z produkcji) i DWA pomiary strażnicze — wiązanie
  („produkcja NIE liczy tego drugi raz") ORAZ zachowanie (prawdziwa maszyna faz
  przechodzi fazę po skróconym limicie). Sam pomiar tekstu jest słaby, sam
  behawioralny nie pilnuje wpięcia; razem tworzą parę „jest wykonawca" +
  „wykonawca robi swoje". Etykietuj w komentarzu, który pomiar jest którym.

# Testy negatywne strażników + CZTERY kształty FAŁSZYWEGO FAIL-a (2026-09-28)

Materiał sesyjny do dwóch reguł tej klasy: „strażnik musi umieć paść" oraz
„detektor trzeba przetestować na POPRAWNYCH danych, nie tylko na zepsutych".
Wszystkie przypadki zmierzone w jednej sesji, na żywym repo.

## 1. Test negatywny jako DOMYŚLNY element weryfikatora (nie jednorazowy)

„Strażnik, który nie umie PAŚĆ, jest deklaracją, nie bramką." Zamiast robić
mutację ręcznie raz, wpisz ją do weryfikatora jako tryb `--negative`.
Zmierzony kontrakt na każdy przypadek jest POTRÓJNY:

| pomiar | oczekiwanie | co dowodzi |
|---|---|---|
| strażnik PRZED mutacją | exit 0 | nie jest zepsuty na starcie |
| strażnik PO mutacji kodu | exit != 0 | **umie czerwienieć** (nie jest dekoracją) |
| strażnik PO przywróceniu | exit 0 **i plik == oryginał co do bajtu** | nie jest „zawsze czerwony" i sprzątanie działa |

Trzeci pomiar bywa pomijany — a to on łapie „strażnik czerwony z innego powodu"
oraz „mutacja nie została cofnięta".

```python
def run_negative(cases):           # cases: (path, needle, replacement, cmd, label)
    for path, needle, repl, cmd, label in cases:
        src = open(path, encoding="utf-8").read()
        assert needle in src, "wzorzec do zepsucia zniknął — zaktualizuj przypadek"
        before  = run(cmd)
        flip(path, src, needle, repl)      # mutacja
        mutated = run(cmd)
        flip(path, src, needle, None)      # przywrócenie
        restored = run(cmd)
        assert before.returncode == 0
        assert mutated.returncode != 0
        assert restored.returncode == 0 and open(path).read() == src
```

Zmierzone przypadki (repo gry): (a) zestaw wypadnięty z bramki →
strażnik pokrycia FAIL; (b) powrót zdublowanej definicji fazy w produkcji →
strażnik tempa FAIL; (c) powrót pustego `task.spawn` w rigu → strażnik monolitu
FAIL. Wynik po wpięciu: 49 PASS / 0 FAIL (40 zwykłych + 9 negatywnych).

**Kontrola integralności na poziomie DRZEWA**, nie plików: odcisk
`git status --porcelain` + `git diff | sha256sum` PRZED i PO całym przebiegu
negatywnym. Jeśli się różni — mutacja nie została cofnięta. To tańsze i mocniejsze
niż porównywanie plik po pliku, i łapie pliki-śmieci, które przy okazji powstały.

## 2. Cztery kształty FAŁSZYWEGO FAIL-a (wszystkie moje, jeden po drugim)

Fałszywy FAIL to nie „nadgorliwość" — to defekt detektora, który kosztuje
zaufanie do bramki i zaprasza do „naprawy" poprawnego kodu. Zmierzone kształty:

**(a) Fraza ZACYTOWANA jako nieprawda.** Detektor szukał
„NIE MA jeszcze ani jednego pliku dźwiękowego" i zapalał FAIL — a dokument
CYTOWAŁ tę frazę właśnie po to, by ją sprostować („poprzednia wersja twierdziła
X, to już nieprawda"). **Lekcja:** obecność frazy ≠ teza. Sprawdzaj KONTEKST
zdania (czy w linii nie ma „nieprawda"/„sprostowanie"), nie samo trafienie.

**(b) Fraza HISTORYCZNA, prawdziwa w swoim czasie.** Ten sam dokument ma wpisy
wersjonowane: „w v10 nie było plików dźwiękowych" było PRAWDZIWE w v10.
Detektor bez zakresu zapalał FAIL na zapisie historii. **Lekcja:** najpierw
wytnij SEKCJĘ, której dotyczy reguła (np. `re.split(r"^WERSJA ", text)` → bierz
`parts[1]`), potem sprawdzaj. „Nazwij ROLE wartości, zanim porównasz" — rola
„zapis historyczny" i rola „teza bieżąca" to dwie różne rzeczy.

**(c) Oczekiwana wartość ZASZYTA w weryfikatorze.** Weryfikator dostawy miał
wpisane `gra-v17-2037.zip` i po wystawieniu v19 zapalił DWA fałszywe FAIL-e
(„NAJNOWSZA to v17", „hash gry == build"), bo porównywał stałą, nie dostawę.
**Lekcja:** oczekiwanie czytaj z artefaktu, który testujesz
(`re.search(r'<a href="/(gra-v\d+-\d+\.zip)"', page)`), nigdy nie wpisuj wersji,
ścieżki ani ID na sztywno. Ten sam defekt co „test mierzy własną kopię".

**(d) Niepełna WHITELISTA tego, co legalne.** Kontrola „repo czyste" miała listę
plików bieżącej fali; gdy w trakcie przebiegu doszedł plik innego strumienia,
zapaliła FAIL na POPRAWNYM stanie. **Lekcja:** whitelista legalnych artefaktów
musi być JAWNA i AKTUALNA — ale nie „cokolwiek" (to czyni kontrolę pustą).
Rozszerzaj ją o konkretne zadeklarowane ścieżki, nie o wzorzec `*`.

Bonus tej samej rodziny: licznik porażek liczony jako `grep -c "FAIL"` zapalał
się na ZIELONEJ bramce, bo jeden test NAZYWA się „(nowa odznaka = FAIL, nie
ciche pominięcie)". Licz `[0-9]+ FAIL` i linie `^FAIL `, nie wystąpienia słowa.

## 3. Strażnik POZA bramką — znalezisko i naprawa klasy

Zmierzone: plik strażnika **616 linii** (warstwa GLUE dla monolitu) nie był
wywoływany przez skrypt bramki ani CI. Przy pierwszym uruchomieniu: 34 PASS,
**3 FAIL** — więc bramka mówiła „wszystko zielone", bo o pliku nie wiedziała.

Reguła klasy: **każdy plik testowy na dysku MUSI być wywołany przez bramkę**.
Strażnik tego (kilkanaście linii Pythona, wyjątki z JAWNYM powodem):

```
EXEMPT = {"harness.lua": "biblioteka atrapy API (nie zestaw)"}
# + pomiń *.client.lua (sondy uruchamiane w Studio, nie pod lua5.1)
# FAIL gdy: plik na dysku, brak wywołania w bramce  ALBO  bramka woła nieistniejący
```

Zmierzone po wpięciu: 26 plików na dysku, 25 w bramce, 0 poza, 0 sierot.

**Diagnostyka „czy to moja regresja?"** — gdy uruchomiony po raz pierwszy
strażnik pada: tymczasowo PRZYWRÓĆ stary kod (`cp` kopii, podmiana linii,
uruchom, `cmp` z kopią) i zobacz, czy pada IDENTYCZNIE. U nas padło tak samo →
dług sprzed zmiany, nie moja wina. Bez tego kroku zgłosisz cudzy dług jako
swój, albo (gorzej) zaczniesz „naprawiać" produkt pod zepsuty rig.

## 4. Defekt RIGU udający defekt PRODUKTU

Ten sam strażnik padał, bo w rigу `_G.task.spawn` był pustym `function() end`,
a komentarz obiecywał `flush`, którego w pliku NIE BYŁO. Skutek: ładowanie
profilu (`task.spawn(Profiles.load)` w `PlayerAdded`) nigdy nie ruszało →
gracz zostawał w `status=LOADING` → monolit nie wychodził z fazy `WAITING` →
trzy asercje (faza DAY, NIGHT, spawn NPC) padały.

Naprawa wzorca: spawn na KORUTYNIE, `task.wait` oddaje sterowanie (yield), więc
pętla `while true` w produkcji zatrzymuje się po pierwszym czekaniu zamiast
wieszać zestaw (dawny objaw: `EXIT=124`, pusty stdout). Gdyby `task.wait` mógł
polecieć z wątku głównego, `yield` rzuca — osłoń:
`if coroutine.running() then coroutine.yield() end`.

**Wniosek pomiarowy:** „komentarz obiecuje mechanizm, którego w pliku nie ma"
to samodzielny wzorzec defektu (ta sama klasa co „suwak bez konsumenta").
Gdy diagnozujesz czerwony zestaw, najpierw sprawdź RIG (czym karmisz moduł),
potem produkt — i nazwij w raporcie, którą warstwę naprawiłeś.

## 5. Wrapper ad-hoc w /tmp JEST KODEM — i sam się psuje

Skrypt weryfikacyjny w `/tmp` (jednorazowy, „byle odpalić") dał w tej sesji
TRZY własne błędy, każdy kosztował turę:

**(a) `exit=127` — nie da się wyliczyć korzenia repo z `$0`.** Wrapper leżał
w `/tmp`, więc `cd "$(dirname "$0")/.."` ustawiło katalog na `/` i próbowało
wołać `//scripts/build.sh`. **Fix:** korzeń JAWNY
(`ROOT="${MIKI_ROOT:-/opt/projects/miki}"`) plus asercje istnienia
(`test -x "$ROOT/scripts/build.sh"`) — nie arytmetyka na ścieżce własnego pliku,
gdy sam leżysz w katalogu tymczasowym.

**(b) `exit=126` — brak bitu wykonywalnego.** Wrapper wołał skrypty repo
wprost; nowe pliki miały `0600`/`0644`. **Fix:** wołaj interpreter jawnie
(`python3 "$ROOT/scripts/…"`), a skrypty przewidziane do uruchamiania dostaw
`chmod 755` i potwierdź `stat -c '%a'` jako dowodem, nie „na oko".

**(c) Sprzątanie, które NAROBIŁO śmieci.** Pętla przywracająca backupy robiła
`cp "$backup" "$ROOT/<basename-z-podkreśleniami>"` → w korzeniu repo wylądowały
`scripts_build.sh`, `src_server_ServerRuntime.lua`, `tests_serverruntime_glue.lua`
(dokładnie ta klasa, którą sam tępisz: śmieć udający plik projektu).
**Fix:** backup trzymaj w katalogu tymczasowym z ZACHOWANĄ strukturą i przywracaj
pod ORYGINALNĄ ścieżką; po przebiegu sprawdź `git status --short` i porównaj
odcisk drzewa przed/po.

**Reguła praktyczna:** po każdym przebiegu wrappera sprawdź `git status --short`.
Jeśli w repo pojawiło się cokolwiek, czego nie utworzyłeś świadomie — to defekt
wrappera, nie „efekt uboczny". Wrapper mutujący repo musi mieć własny kontrakt
czystości: kopia z oryginalną strukturą, przywrócenie pod oryginalną nazwą,
odcisk drzewa przed/po.

**Domknięcie:** dowód nie mieszka w `/tmp`. Skrypt, który zadziałał, przenieś do
repo jako trwały weryfikator (`scripts/verify-*.py`) i uruchamiaj go stamtąd;
pliki z `/tmp` wolno kasować TYLKO wtedy, gdy trwała wersja istnieje.


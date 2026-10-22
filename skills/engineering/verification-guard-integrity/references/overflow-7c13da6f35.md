---
name: verification-guard-integrity
description: >
  Pisz sprawdziany (strażniki, bramki, testy kontraktowe), które NIE MOGĄ skłamać,
  i triażuj padające sprawdzenie bez kłamania w drugą stronę. Użyj, gdy: ogłaszasz
  werdykt „defekt / brak / dostarczone / flaky", piszesz test weryfikujący własną
  zmianę, diagnozujesz czerwony gate, albo mierzysz „czy coś jest / działa / jest
  wdrożone". Klasa obejmuje trzy pułapki tożsamości pomiaru (mierzysz nie tę KOPIĘ,
  nie ten ADRES, nie tę ROLĘ), rejestry/wpisy GENEROWANE ze SSOT (determinizm generatora,
  unikalność id, meta-bramka; granice/strażnicy: UŻYCIE≠OPIS, tamper kopii) — references/, semantykę progu FAIL vs WARN (zanim nazwiesz coś
  „niestałym"), oraz autorstwo strażnika (porównania literałowe na wyjściu narzędzia,
  brak testu negatywnego, strażnik w katalogu, którego runner nie odwiedza).
  Detektor zbyt szeroki / samo-zatrucie skanu i weryfikacja pliku po delegacji:
  patrz references/.
---

> **Granice strażnika (2026-10-01):** bramka, która **WISI** (podproces per-linia →
> brak EXIT), auto-remediacja, która **wychodzi z zakresu przez symlink**
> (`chmod`/`chown` na dowiązaniu działa na CELU → zabiła systemowe `python3`),
> oraz strażnik **za szeroki**, który blokuje commit wszystkim z powodu cudzej pracy
> w toku (`ls-tree HEAD`, nie `ls-files`). Objaw → pytanie → brakująca granica
> w tabeli: `references/guard-hangs-and-escapes-scope-2026-10-01.md`.

> **Patrz też:** `references/wiszaca-bramka-i-pulapki-pomiaru.md` — cztery pułapki
> zmierzone 2026-10-01: (1) bramka **WISZĄCA** (grep na każdą linię → brak werdyktu;
> wisząca bramka jest gorsza od czerwonej), (2) wejście do zbioru z fallbacku na dysk
> wciąga śmietnik (`.dustbin-*` → 109 tys. fałszywych trafień), (3) porównanie
> **hash hosta za symlinkiem** z hash symlinku rozwiązanego w innym namespace =
> trwały fałszywy DRIFT (dowód: `docker exec sha256sum`), (4) werdykt FAIL **bez nazw
> naruszających ścieżek** jest bezużyteczny.

# Verification Guard Integrity

Strażnik/bramka ma JEDNO zadanie: **nie skłamać**. Ten skill zbiera tryby, w
których kłamie — po obu stronach (fałszywy zielony i fałszywy czerwony) — oraz
sposób ich wykrycia i leczenia.

## Trzy pułapki tożsamości pomiaru

Zanim ogłosisz werdykt, ustal TOŻSAMOŚĆ tego, co mierzone:

1. **Nie ta KOPIA** — mierzysz plik z dysku, a działa inny (duplikat drzewa,
   plik w obrazie, plik z bind-mountu). Ustal, KTÓRA kopia jest w hot path.
2. **Nie ten ADRES** — mierzysz `localhost`, a produkt chodzi pod domeną
   (proxy, tunel, edge). Zmierz TĘ warstwę, którą widzi użytkownik.
3. **Nie ta ROLA** — dwie wartości są różne, ale pełnią różne role, więc
   równość NIE jest kontraktem (rozmiar pliku na dysku vs przez HTTP z
   kompresją — oba poprawne).

**Reguła nadrzędna:** przy każdym CZERWONYM najpierw sprawdź, czy detektor
patrzy na właściwą rzecz — ZANIM uznasz defekt i „naprawisz" kod pod test.

## Sześć trybów fałszywego zielonego/czerwonego

Pełny opis z kodem: `references/gate-falsy-green-modes.md`.

1. **Furtka `-x`/`-f` — zielono bez pomiaru.** Bramka stawia warunek na PLIKU
   dowodu, nie na WYNIKU. Artefakt traci bit `+x` → gałąź „pomiń pomiar" →
   zielono bez ani jednego pomiaru. **Leczenie:** krok dowodowy przez
   `python3 <plik>` / `bash <plik>`; brak artefaktu = `fail=1`, nigdy „pomiń".
   Każdy `[ -x ]`/`[ -f ]` wokół testu to podejrzany.
2. **Pętla weryfikacyjna mierzy samą siebie.** Endpoint z rate-limitem (429)
   + skrypt robiący kilka przebiegów = limit wyczerpany przez pomiar. Objaw:
   `429` na POPRAWNYCH danych wyglądające jak regresja. **Leczenie:** odczekanie
   okna między podtestami; w werdykcie RÓŻNICUJ `429` (limit) / `401` (zły
   sekret) / `403` (WAF/proxy).
3. **`403` od Cloudflare WAF na User-Agent `curl`.** Pomiar przez publiczną
   domenę zwraca `403` na poprawnych danych, bo CF klasyfikuje
   `curl/x.y`, `Python-urllib/x.y` jako bota. **Leczenie:** UA przeglądarki w
   skryptach mierzących przez domenę. `403` + `server: cloudflare` = POMIAR
   NIEWAŻNY, nie werdykt aplikacji.
4. **Detektor ślepy — `grep` na zbyt dosłownym wzorcu.** `grep 'X 401'` nie
   łapie `X HTTP 401 tekst`. **Leczenie:** dopasowuj tokeny osobno.
5. **Detektor zawsze-OK.** Odwrotność nr 4 i trudniejsza do zauważenia.
   Test „detektor widzi porażkę" jest OBOWIĄZKOWY: podaj zły sekret i wymagaj
   PORAŻKI.
6. **Raportowanie nieaktualnego przebiegu.** System pokazuje wynik sprzed
   poprawek. Nie broń starego przebiegu — unieważnij, zmierz od nowa na obecnym
   stanie i podaj `md5sum` plików razem z wynikiem.
7. **`grep` łapie KOMENTARZ, nie kod.** Najczęstszy fałszywy alarm tej klasy
   i najłatwiejszy do przeoczenia, bo wygląda jak realne znalezisko.
   Zmierzone 2026-09-30 (trzy razy w jednej sesji):
   - `grep -c 'weights_only=False'` w patchu → trafił w **komentarz**, który tę
     frazę tylko OPISYWAŁ („zamiast wyłączać ochronę przez `weights_only=False`");
   - `grep -c 'savefig'` → policzył `savefig.facecolor` ze stylu `rcParams`,
     dając 6 dla 5 wykresów;
   - `grep -c '\b138\b'` (zakaz hardkodu) → trafił w komentarz tłumaczący,
     dlaczego hardkod usunięto.

   **Leczenie — mierz KOD, nie tekst pliku:**
   ```bash
   # usuń komentarze PRZED grepem:
   KOD=$(grep -vE '^\s*#' plik) ; grep -q 'wzorzec' <<<"$KOD"
   ```
   Dla Pythona użyj `ast`/`tokenize` (odsiewa `COMMENT` **strukturalnie**, nie
   po prefiksie linii). Przy liczeniu konstrukcji licz **wywołania**, nie
   wystąpienia podłańcucha: `grep -c 'plt\.savefig('`, nie `grep -c savefig`.
8. **Detektor na MIANOWNIKU, dane w NARZĘDNIKU.** Wzorzec dosłowny nie łapie
   odmiany wyrazu ani tego, jak narzędzie realnie zapisuje wartość.
   Zmierzone 2026-09-30:
   - test szukał `analiza konkurencyjna`; dokument miał `analizą konkurencyjną`
     → fałszywy FAIL na poprawnym PDF-ie;
   - PDF ma `prof. Krzysztofa Rządcy` (dopełniacz), test wymagał `Rządca`;
   - kod używa `n_vocab=num_symbols` (zmienna LOKALNA), test wymagał
     `self.hparams.num_symbols` → „pole bez źródła" na POPRAWNYM kodzie;
   - `extract_text()` wstawia twardą spację `\u00a0` i łamie frazę między
     tagami — test na dokładnym stringu nie trafiał.

   **Leczenie:** dopasowuj **rdzeń wyrazu** (`konkurencyjn`, `Rządc`,
   `num_symbols`), normalizuj białe znaki (`re.sub(r'[\s\u00a0]+',' ',t)`),
   a przy teście „czy pole jest używane" sprawdzaj **dowolną formę
   odniesienia do nazwy**, nie jedną konkretną.

9. **Zielona bramka mierzy NIE TEN TYP ARTEFAKTU.** Repo ma jeden „test" na
   wejściu (`npm test`), ale zmiana jest w języku, którego runner NIE dotyka.
   Zmierzone 2026-09-30 (`<workspace>`): `npm test` = `bash tools/test fast`
   (TestForge, JS/TS/Python); `grep -c cargo tools/test` = **0** — ani jednego
   wywołania cargo. Zmiana w `backend-rs/src/handlers/proxy.rs` (crate Rust,
   `Cargo.toml`, BRAK `package.json`) przeszłaby przez `npm test` **niezależnie
   od tego, czy kod się kompiluje**. Bramka zielona z natury — nie mierzy
   edytowanego pliku.

   **Leczenie — dopasuj bramkę do typu artefaktu, nie do wygody:**
   ```bash
   # co runner REALNIE uruchamia (zanim mu zaufasz):
   grep -c cargo tools/test        # 0 = Rust NIE jest mierzony
   grep -E '^test:' package.json   # co kryje się za 'npm test' (wrapper, nie JS!)
   ```
   Dla crates: `cargo test -p <crate> --lib <filtr>` + `cargo check -p <crate>`
   (dowód kompilacji). `npm test` **dodatkowo**, nigdy **zamiast**.

   **Wariant §9 zmierzony 2026-10-12: `npm run test` w PODKATALOGU uruchamia CUDZY
   suite.** W repo-workspace `npm` rozwiązuje `package.json` **RODZICA** — w
   `products/optiq/grafik/` `npm run test` odpaliło `aigon-x-prod-stack@0.1.0 →
   bash tools/test fast` (TestForge), nie nic związanego z edytowanym plikiem.
   Zanim ogłosisz „testy zielone/czerwone", potwierdź, KTÓRY projekt npm realnie
   chodzi (`npm run test 2>&1 | head -3` pokazuje nazwę workspace). **Werdykt bierz
   z LINII MASZYNOWEJ runnera** (`SUITE: PASS`, `Total: N PASS: N FAIL: 0 ERROR: 0`)
   **+ kodu wyjścia procesu** — NIE z `grep -c FAIL` po logu: słowo `FAIL` pada też
   w opisach przypadków (`tf_result FAIL zwraca rc=1`, `NO-FALSE-GREEN`), więc grep
   dał **14 „porażek" na zielonym suite** (rozszerzenie §7 „licz konstrukcje, nie
   podłańcuchy" na logi PASS/FAIL).

10. **FALSE GATE — harness testowy zwraca ERROR zamiast FAIL i maskuje
    podległą bramkę.** Objaw dokładny do rozpoznania:
    `[ERROR] RUN tests/unit/<plik>.test.sh` +
    `test nie wyprodukował test-results.json (nie zakończył się przez tf_exit)`.
    To nie jest porażka TEGO testu — to znaczy, że podległa bramka wywołana
    wewnątrz testu zwróciła rc≠0 i przerwała test przed zapisem wyniku.
    Prawdziwy defekt jest O PIĘTRO NIŻEJ.

    **Leczenie — idź do podległej bramki, uruchom ją wprost:**
    ```bash
    # z komunikatu wyżej wynika KTÓRA bramka padła; uruchom ją z jej realną ścieżką:
    bash tools/verify/gates/domains/<bramka>.sh --verify   # pełny komunikat + RC
    ```
    Zmierzone 2026-09-30: `limits-render-bypass.test.sh` → ERROR; realny defekt
    to `limits-ssot` zgłaszający `2 rozjazdów SSOT ↔ rzeczywistość` (usługi miały
    limity w compose, brak w SSOT). Po dopisaniu do SSOT: `--verify` PASS,
    `npm test` SUITE: PASS (8/8, było ERROR: 1).

    **PUŁAPKA ścieżki:** delegat `tools/gates/<id>.sh` to NIE ta sama ścieżka co
    implementacja `tools/verify/gates/domains/<id>.sh`. Wywołanie delegata bez
    argumentów potrafi zwrócić rc=0 mimo FAIL (bo delegat exec-uje z innym
    zestawem flag). Wołaj **implementację** z jawnym `--verify`.

    **DRUGA PRZYCZYNA tego samego objawu (zmierzona 2026-09-30) — test źródłuje
    NIEISTNIEJĄCĄ bibliotekę i wpada we własny fallback.** Rozróżniaj po tym, czy
    w komunikacie jest „nie produkował test-results.json", a test **samodzielnie**
    przechodzi na zielono:

    ```bash
    # test standalone: 8/8 PASS, RC=0     ← wygląda dobrze
    # ten sam test w bramie: [ERROR] FALSE GATE
    ```

    Test miał `TF="$ROOT/tools/testing/testforge.sh"` + `[ -r "$TF" ] && . "$TF"`
    + własny fallback `tf_pass()`/`tf_fail()` gdy źródłowanie się nie powiedzie.
    **Plik `testforge.sh` NIE ISTNIEJE** (biblioteka to `lib.sh`) → warunek
    `-r` fałszywy → fallback → asercje drukowane (8/8 PASS), ale **brak
    `tf_exit`/`tf_summary`** → nie powstaje `test-results.json` → runner:
    `[ERROR] ... FALSE GATE`. Samodzielnie test kończył `exit 0`, więc defekt
    był niewidoczny poza bramą.

    **Reguła rozpoznawcza:** gdy test w bramie daje ERROR, a standalone PASS —
    sprawdź, czy test **ładuje tę samą bibliotekę co działające testy**:
    ```bash
    grep -nE '^\s*\.\s|source ' tests/unit/<test>.test.sh     # co źródłuje
    grep -nE '^\s*\.\s' tests/unit/state.test.sh              # WZORZEC działającego
    ```
    Wzorzec poprawny: ścieżka **względna od pliku testu**, odporna na CWD:
    ```bash
    . "$(dirname "${BASH_SOURCE[0]}")/../../tools/testing/lib.sh"
    ```
    I zakończenie przez `tf_exit "<NAZWA>"` (pisze JSON + propaguje kod), NIGDY
    `tf_result` bez argumentów — `tf_result` ma sygnaturę `<status> <name> [detail]`,
    więc wywołane bez nich daje `status=''` → `[ERROR] (nieznany status '')`.

    **TRZECIA PRZYCZYNA tego samego objawu (zmierzona 2026-09-30) — ROZJAZD
    BUDŻETÓW CZASU między testem a podległym skryptem.** Test woła podległy
    skrypt przez `timeout N`, a skrypt ma WŁASNE wewnętrzne timeouty, których
    suma przekracza N. Skrypt jest ubijany w połowie → nie kończy → nie pisze
    `test-results.json` → `[ERROR]`.

    Zmierzone: `tests/unit/ollama-model-guard.test.sh` dawał `timeout 240` na
    guard, a guard ma wewnętrznie `timeout 90` (reaper) + `120` + `120`
    (self-heal --apply) = **do ~330 s**. Objaw: raz ERROR, raz PASS (zależnie
    od tego, czy guard zdążył) — wyglądał jak flake, a był arytmetyką.

    **Reguła rozpoznawcza — zanim nazwiesz to flaky, policz budżety:**
    ```bash
    grep -nE 'timeout [0-9]+' tests/unit/<test>.test.sh          # budżet testu
    grep -nE 'timeout [0-9]+' scripts/<skrypt-podlegly>.sh       # SUMY wewnętrzne
    # budżet testu MUSI >= suma wewnętrznych timeoutów + zapas
    ```
    **Leczenie:** zsynchronizuj budżet testu z sumą wewnętrznych timeoutów
    podległego skryptu (+ zapas) i **zapisz w komentarzu arytmetykę**, żeby
    następny czytelnik nie musiał jej odtwarzać. Gdy skrypt nie ma własnych
    timeoutów, a wisi — problem jest gdzie indziej (patrz punkty wyżej).

    **Leczenie wspólne dla obu przyczyn:** test MUSI kończyć się `tf_exit`
    (dowód: po przebiegu istnieje `test-results.json` z licznikami). Weryfikuj:
    ```bash
    D=$(mktemp -d); TESTFORGE_RESULTS_DIR=$D bash tests/unit/<test>.test.sh
    cat $D/test-results.json    # {"suite":...,"total":N,"pass":N,...}
    ```
    Brak pliku = test nie jest podpięty do harnessu, niezależnie od tego, ile
    PASS-ów wydrukował. Fallback pisany „na wszelki wypadek" w teście **maskuje
    rozjazd konfiguracji** — usuń go, jeśli harness jest zawsze dostępny.

11. **Bramka mierzy POCHODNĄ STANU, gdy kanon wymaga ARTEFAKTU** (zmierzone
    2026-09-30, `mesh-duty.sh` W5). Groźniejsza od pozostałych, bo kryterium było
    **obniżone świadomie** i uzasadnione komentarzem — więc wygląda jak decyzja,
    a jest maskowaniem brakującej funkcji.

    Kanon `LAW-MESH-1`: „wynik MUSI wracać **SYNTEZĄ** (status done), nie jako
    porzucone strzępy". Kod nadawał `done` gdy wszystkie subtaski wróciły —
    **bez składania wyniku** (`finish_if_complete`). Bramka mierzyła
    `N_DONE >= 1` (jest choć jedno `done`). Zadanie `85b3d9e0` („Policz sumę
    1..100") = `done`, 1 subtask, wynik = surowy output modelu → bramka
    **przepuściła**, bo status był zielony.

    Nagłówek bramki zawierał zdanie-usprawiedliwienie:
    `# W5 mierzy NIE „czy mesh obiecał syntezę", tylko „czy praca wróciła"`
    To NIE decyzja projektowa — to **konsekwencja braku funkcji w kodzie**,
    przebrana za świadomy wybór. Gdy funkcja powstała, kryterium wróciło do kanonu.

    **Reguła rozpoznawcza:** gdy bramka mierzy pole **pochodne** stanu
    (`status == "done"`, `>= 1 sukces`, `len > 0`) zamiast **artefaktu**
    (`artifact.is_some()`, plik istnieje, hash się zgadza) — sprawdź, czy kanon
    nie wymaga artefaktu. `done` mówi „proces się zakończył"; artefakt mówi
    „wynik istnieje i jest tym, o co proszono". Pierwsze jest tańsze i dlatego
    kusi jako kryterium.

    **Leczenie — trzy strony, wszystkie obowiązkowe:**
    - **KOD wytwarza artefakt** (nowy krok kaskady, pole w stanie, funkcja
      zbierająca idempotentna — znacznik ustawiany w tej samej transakcji, żeby
      zadanie trafiło do syntezy DOKŁADNIE raz).
    - **API wystawia artefakt**, inaczej bramka nie ma wejścia:
      `"artifact_present": t.artifact.is_some()` w `GET /status`.
    - **Bramka mierzy artefakt, ale `NODATA` NIE zmienia werdyktu** (starszy
      runtime bez pola = brak danych != złamanie). Trzy stany: `OK` /
      `MISSING` (done + brak artefaktu + krok nie startował = złamane) / `NODATA`.

    **Logika pomiaru jako osobny skrypt, nie heredoc w bramce.** Heredok
    `<<'PY'` wewnątrz `$(...)` w bashu jest kruchy (zagnieżdżone `$()`,
    cudzysłowy w `-H "X: $SECRET"`), a `bash -n` pokazuje błąd w linii DALEKO od
    przyczyny. Zmierzone: 4 nieudane próby naprawy w miejscu, zanim rozdzielono
    pomiar do `mesh-duty-w5.py` (kontrakt: **jeden token na stdout**) i bramka
    woła go jedną linią. **Gdy blok bash rośnie ponad ~15 linii logiki —
    wynieś go do skryptu obok bramki.** Dodatkowo: zmienna `GATE_DIR` bywa
    nieustawiona — używaj istniejącego `ROOT` (`$ROOT/tools/gates/...`).

## 12. Race w teście bramki — pomiar trafia w okno PRZEJŚCIOWE (2026-09-30)

**Objaw:** ten sam test daje FAIL, a po powtórzeniu PASS — na niezmienionym
kodzie. Wygląda jak flake, jest **odczytem w trakcie zapisu**.

Zmierzone na `tests/unit/ollama-model-guard.test.sh` (OMG-007): test czytał
uprawnienia metryki JEDNYM `stat`. Cron guardu chodzi co minutę i pisze plik
przez `mv` (664) → potem `chmod 644`. Test trafiający w to okno widział `664`
i ogłaszał FAIL na sprawnym guardzie. Plik w spoczynku: `644 root:root`.

**Reguła rozpoznawcza:** jeśli FAIL znika przy powtórzeniu i dotyczy artefaktu,
który **inny proces regularnie zapisuje** (metryka textfile, log, plik stanu,
artefakt cronu) — to nie flake, to race odczytu.

**Leczenie — retry na stanie USTALONYM, nie maskowanie:**
```bash
perm=""; for _try in 1 2 3 4 5; do
  perm="$(stat -c '%a %U:%G' "$PLIK" 2>/dev/null)"
  [ "$perm" = "644 root:root" ] && break
  sleep 1
done
# werdykt z perm po pętli; prawdziwy defekt (trwałe 664) NIE przejdzie 5 prób
```
To **nie** osłabia bramki: trwały rozjazd uprawnień zostanie wykryty po 5 próbach
w 5 s. Różnica między retry a maskowaniem: retry czeka na stan spoczynku,
maskowanie rezygnuje z pomiaru.

**Kontekst:** ta klasa jest **rodzeństwem** pkt 11 — obie polegają na mierzeniu
czegoś, co nie jest jeszcze ustalone. Zawsze pytaj: **czy artefakt, który mierzę,
jest w stanie ustalonym?**

## 13. Symlink: porównanie ŚCIEŻEK daje fałszywy DRIFT, samo sha256 gubi przypadek (2026-09-30)

**Klasa podwójnej pułapki — dwie różne bramki, dwa przeciwne błędy na tym samym
pliku (`/etc/localtime`).** Oba zmierzone, oba trzeba znać osobno.

**Pułapka A — bramka porównuje sha256 TREŚCI CELU symlinka.**
`config-consistency.sh` czytała bind-mount przez `docker cp <ctr>:<dst>`. Dla
`/etc/localtime` (symlink) docker cp kopiuje **sam symlink**, więc sha256 liczył
się z pliku docelowego: host `Europe/Warsaw` vs kontener `Etc/UTC`. Porównanie
dwóch **różnych stref czasowych jako tego samego pliku**. Rozstrzygnięcie:
kontener ma **osobny plik** strefy (inode różny!), mimo deklarowanego bind-mountu.

**Pułapka B — bramka porównuje ROZWIĄZANE ŚCIEŻKI (`readlink -f`).**
Próba naprawy A przez `readlink -f` dała **odwrotny** błąd: dla **zwykłego
pliku** `readlink -f` zwraca własną ścieżkę, więc plik zamontowany pod **inną
ścieżką** (`aigon-code`: host `~/.local/bin/`, kontener `/usr/local/bin/`)
dostawał fałszywy DRIFT. Dodatkowo łańcuch symlinków rozwiązuje się różnie
w kontenerze, bo kontener nie ma ogniw łańcucha hosta.

**Trzecia próba (porównanie treści celów) — COFNIĘTA, bo przeszła na PASS i
przestała wykrywać wstrzyknięty rozjazd.** Test negatywny to zdemaskował.

**Reguła:** w bramkach plikowych **symlink i zwykły plik wymagają różnej metody**
i żadna z dwóch nie jest uniwersalna. Zanim „naprawisz" bramkę porównującą pliki:
1. Uruchom **test negatywny** (wstrzyknij znany rozjazd, wymagaj FAIL).
2. Jeśli po naprawie bramka daje PASS na wstrzykniętym rozjeździe — **naprawa
   jest gorsza od oryginału.** Cofnij ją.
3. **Fałszywy czerwony jest tańszy niż fałszywe zielone.** Fałszywy czerwony
   kosztuje czyjś czas; fałszywe zielone kosztuje niewykryty defekt produkcyjny.

**Diagnostyka symlinku (gdy `date` przeczy `readlink`):**
```bash
stat -c '%i %F' /etc/localtime                          # inode + typ (host)
docker exec <ctr> stat -c '%i %F' /etc/localtime        # inode w kontenerze
docker exec <ctr> readlink -f /etc/localtime            # dokąd wskazuje
docker exec <ctr> md5sum $(docker exec <ctr> readlink -f /etc/localtime)
# RÓŻNE inody = kontener ma WŁASNY plik (bind-mount nie zadziałał na symlinku)
```
Zmierzone: host inode `21761023`, kontener `33192176` — a `date` w kontenerze
pokazywał CEST, bo plik `Etc/UTC` w obrazie miał **treść** warszawską. Kontener
działał POPRAWNIE przez przypadek, nie przez projekt.

## 14. Znacznik testowy w danych produkcyjnych — nie cytuj jako faktu (2026-09-30)

**Objaw:** w bazie kontaktów pole `reply` zawiera odpowiedź naukowca
(„chętnie porozmawiam o współpracy") z dopiskiem **„(test naprawy 2026-09-30)"**.
Sąsiednie rekordy mają **prawdziwe nagłówki maili** (`Od: … Data: … Temat: …`),
a ten jeden ma krótki tekst bez nagłówka (83 znaki vs 4000 u innego).

**Reguła:** zanim użyjesz wartości z bazy jako **przesłanki decyzji**
(„naukowiec się zgodził", „klient odpisał") — sprawdź, czy rekord nie jest
**śladam testu naprawy**. Sygnatury:
- dopisek `(test…)`, `(naprawa…)`, `(seed)`, `(fixture)` w treści,
- brak struktury, którą mają prawdziwe rekordy (nagłówek maila, ID wiadomości),
- długość odstająca od reszty populacji,
- data równa dacie ostatniej operacji na bazie.

**Nie mów Suwerenowi „X odpisał i się zgodził", jeśli rekord jest testem.**
Powiedz: „w bazie jest wpis, ale nosi znacznik testu naprawy — sprawdzę w skrzynce
przed potraktowaniem jako zgody". To ta sama rodzina co fałszywe zielone: **dane
wyglądające jak fakt, którym nie są**.

## 16. Sonda KRÓTSZA niż realna odpowiedź — wieczny fałszywy czerwony (2026-09-30)

**Objaw:** UI/dashboard „nie aktualizuje danych", operator widzi zamrożony stan
i mówi „nie mogę wybrać węzła". Backend jest SPRAWNY (curl z hosta = `200`,
dane świeże). Wygląda jak awaria aplikacji.

**Mechanizm (zmierzony):** endpoint `/api/v1/mesh` odpowiada w **6,6–7,7 s**
(~275 KB: 8 węzłów × macierz serwisów + listy usług), a sonda pollująca miała
**`AMO_PROBE_TIMEOUT=2.0`**. Każdy poll kończył się `POLL FAIL (err) — endpoint
nie odpowiedział podczas pollu co 5 s` → UI stało na ostatnim snapshocie.

**Reguła:** to NIE jest „flaky pod obciążeniem" (inny wariant tej samej rodziny).
To **strukturalna** niezgodność: `timeout sondy < czas odpowiedzi w stanie
ustalonym`. Drgnięcie loadu jej nie tłumaczy — ona zachodzi ZAWSZE.

**Kolejność diagnozy (nie odwrotnie):**
```bash
# 1. ZMIERZ czas odpowiedzi (3 próby — ogon ma znaczenie, nie średnia)
for i in 1 2 3; do curl -s -o /dev/null -w "  HTTP=%{http_code} czas=%{time_total}s\n" <URL>; done
# 2. DOPIERO POTEM ustaw timeout sondy — z zapasem 2-3x nad OGONEM
# 3. Sprawdź, czy sonda mierzy z właściwej warstwy (pkt 1b: nie ten adres)
```

**Leczenie:** podnieś timeout sondy (u nas 2,0 s → 20 s) **oraz** cache TTL
(5 s → 30 s), żeby nie dobijać wielosekundowego endpointu co 5 s. Po naprawie
dane się odświeżają, a liczba przeklikanym tras (200/… zamiast FAIL) idzie w górę.

**Ta sama klasa w innych miejscach tego repo (sprawdź je razem):**
- `runtime/crates/aigon-runtime/crates/aigon-runtime/src/api.rs` — `mesh_probe_service`: **3 s → 8 s**
  (realnie 0,1–3,8 s, ogon 8 s) → macierz raportowała `DOWN` mimo żywego portu.
- `ollama spin-guard` — okno 25 s na generację przy load ~28 → **fałszywy GHOST**
  i flapping zdrowego pasma (poprawka: okno 60 s).

**Reguła generalna:** każda sonda ma DWA niezależne parametry — **co** mierzy
(pkt 1: kopia/adres/rola) i **jak długo czeka**. Zły którykolwiek daje fałszywy
werdykt. Przy każdym „usługa nie odpowiada" najpierw: czy to usługa, czy czekanie.



Zanim nazwiesz coś „niestałym/flaky": ustal, czy próg jest kontraktem, czy
obserwacją. Flake to zmienność PRZY spełnionym kontrakcie. Jeśli kontrakt nie
jest spełniony — to nie flake, to defekt.

## Test negatywny — obowiązkowy

Zielona bramka na poprawnym stanie NICZEGO nie dowodzi. Dowodzi dopiero
pokazanie, że **pada na stanie zepsutym**. Wzorzec ad-hoc (6 podtestów,
`/tmp/hermes-verify-<bramka>.sh`, `trap ... EXIT` sprząta po sobie):

1. przechodzi na stanie poprawnym (RC=0)
2. WYKRYWA wprowadzony defekt (RC≠0 + komunikat nazywający defekt)
3. brak artefaktu dowodu = FAIL, nie ciche pominięcie
4. dowód działa bez bitu `+x`
5. detektor widzi zły sekret (`401`) jako PORAŻKĘ — nie jest ślepy
6. sprzątnięcie zweryfikowane (sonda nie została w bazie/pliku)

**Dwa warianty, wybierz zależnie od tego, CO bramka czyta:**

| bramka czyta | wariant mutacji | dowód |
|---|---|---|
| jeden PLIK na dysku | mutacja pliku + przywrócenie | `git diff \| sha256sum` przed/po == |
| WIELE źródeł (N katalogów, N endpointów) | **monkey-patch w pamięci** — nie tykaj dysku | para EXIT(poprawny) / EXIT(podmieniony) |

Drugi wariant: `references/negative-test-via-monkeypatch.md` (zmierzony:
podmiana `AGENT_SKILL_DIRS` na pusty katalog → bramka `FAIL`, 40 braków;
ta sama bramka na stanie poprawnym → `EXIT=0`). Ma sens, gdy psucie danych
na dysku jest niedopuszczalne (cudza praca, dane produkcyjne, współdzielone
drzewo) — a tak jest prawie zawsze w `<workspace>`.

## 34. Etap/moduł zwraca OK bez swojego WEJŚCIA — stub „niewdrożone" (2026-10-04)

**Objaw:** etap pipeline'u ma status kontraktowy, ale implementacja to stub, który
nie sprawdza swojego wejścia — albo (gorzej) zwraca `OK` bez dowodu. Zmierzone w
`monai-kaggle/pipeline.py`: `stage_validate` zwracał `BLOCKED` z opisem
„...— niewdrożone". Stub jest uczciwy TYLKO dopóki nic nie twierdzi.

**Dwie reguły przy zadaniu „zaimplementuj etap/bramkę":**

1. **Zaimplementowany etap nie może zostawić słowa `niewdrożone`.** Jeśli da się
   walidować wejście — waliduj: brak wejścia → `BLOCKED` z konkretnym powodem
   (`reason="no_artifact"`); złe wejście → `BLOCKED` `invalid_*`; dobre → `OK`.
   Dowód > deklaracja.
2. **Brak mierzalnej wartości = `None`, nie zero ani „OK".** Gdy metryki nie da się
   policzyć (np. brak ground-truth/holdout), zwróć `metric_value: None` + czytelny
   `metric_reason`. Sukces formatu bez metryki to nadal `OK` — o ile brak jest JAWNY.
   (Ten sam wzorzec co §11: bramka mierzy ARTEFAKT, a `NODATA` nie zmienia werdyktu.)

**Weryfikacja takiego etapu w projekcie Python:**

- **Bramka projektu bywa `ci.sh`, nie `npm run test`.** Brak `package.json`/
  `Makefile`/`pyproject` = brak runnera npm. ZANIM ogłosisz „testy się nie uruchomiły",
  ustal realną bramkę: `ls package.json Makefile pyproject.toml ci.sh`. Poprawna
  odpowiedź brzmi „brak npm; bramka = ci.sh — uruchomiłem, zielono", nie „blokada".
  To ten sam obowiązek co §9 (dopasuj bramkę do typu artefaktu) rozciągnięty na JĘZYK.
- **Stałe modułu czytane przy IMPORCIE.** Katalogi/limity (`…_DIR`, `_MAX_ROWS`) są
  liczone raz w chwili `import`. W testach ustaw env PRZED `import`, inaczej test
  pisze do PRODUKCYJNEGO katalogu stanu. (Rodzina §1a — test mierzy nie tę kopię.)
- **Typowanie (Pyright/mypy) NIE zawęża po `any(x is None for x in lst)`** — po takim
  guardzie `list[float|None]` nadal krzyczy przy arytmetyce. Użyj jawnej pętli z
  `if x is None: <bail>` przed `append`.
- **Test negatywny etapu (obowiązkowy, wzorzec z „Test negatywny" wyżej):**
  brak wejścia → `BLOCKED` (NIE `OK`); wejście złe (brak kolumny ID/target, duplikaty,
  puste wartości) → `BLOCKED invalid_*`; wejście dobre → `OK`. Dodatkowo: brak holdout
  → `metric_value=None` (nie zmyślone); z holdout → metryka policzona.

**Wzorzec walidacji artefaktu (ID+target), reprodukowalny:** heurystyka nagłówka dla
kolumny ID (`id,image_id,row_id,sample_id,case_id,...`) i target (`target,label,
prediction,pred,score,probability,...`); odrzuć puste targety, duplikaty ID, <2 kolumny;
limit bezpieczeństwa na liczbę wierszy. Metrykę licz WYŁĄCZNIE na realnym ground-truth,
z jawnym env-override; auto-dobór (`accuracy` dla całkowitoliczbowych etykiet, `rmse`
dla ciągłych) i NIGDY nie zgaduj liczby.

## Falsyfikowalność egzekucji praw/reguł (prawo bez mutacji = dekoracja)

Gdy bramkujesz WARSTWĘ PRAW (konstytucja/policy-as-code: `law-id → fitness_cmd →
trigger`), samo pokrycie nie wystarcza. Reguła:

- **Reguła anty-tautologiczna:** żaden fitness_cmd nie może brać baseline'u z
  tego samego pliku, który mierzy. Porównuj *deklarację vs żywy byt* (runtime/DB)
  albo *zbiór A vs niezależny zbiór B*. Zmierzone: bramka porównywała manifest z
  manifestem → „PASS (44)", runtime miał 35 → 9 martwych kerneli.
- **Każde prawo musi mieć mutację:** wpis `mutate_cmd` + `expect_exit: 1`.
  Prawo z wykonawcą, ale bez mutacji, liczy się jako **0** (nie „zaliczone").
- **Meta-harness:** kopia drzewa do `mktemp -d` → fitness na czystej kopii
  (expect 0) → wstrzyknij naruszenie → fitness (expect 1). Kontrola=1 LUB
  mutacja=0 → FAIL meta-bramki. Nigdy nie mutuj produkcji współdzielonej.
- **Ratchet, nie 100%:** próg 100% przy 0/86 prawach z wykonawcą blokuje KAŻDY
  push całej flocie — paraliż, nie egzekucja. Analizę statyczną wpinaj w FAST
  (pre-commit, łapie autora), mutacje w STANDARD (pre-push).
- **Wspólna klasa luk:** nikt nie mierzy relacji między ZBIORAMI (kanon ↔ agent
  ↔ manifest ↔ rdzeń). „Ile jest" ≠ „czy się zgadza".

Projekt pełny + 5 zmierzonych luk + gotowy harness:
`references/law-falsifiability-enforcement-design.md`.
Bramka wieloźródłowa: `scripts/skill-registry-integrity.py`.

## 15. Obietnica ZDOLNOŚCI a pomiar zdolności — „testy przechodzą" ≠ „zdolność działa" (2026-10-01)

**Objaw:** kod/endpoint obiecuje zdolność (tolerancja N utrat, auto-recovery,
FEC, rekonstrukcja z redundancji), a testy w repo są zielone — ale **żaden test
nie egzekwuje tej obietnicy** na właściwej ścieżce.

Trzy warianty (wszystkie zmierzone na audycie Reed-Solomon, `<workspace>`):

- **Słaba asercja maskuje brak zdolności.** Test usuwał 2 shardy i asertował
  `assert!(!healed.is_empty())` — przeszedłby nawet na **całkowicie innych
  bajtach**. Każdy test „odzyskiwania/rekonstrukcji/dekodowania" MUSI kończyć
  się `assert_eq!(result, original)`, nigdy `!is_empty()` / `is_ok()` / `len>0`.
- **Advertised ≠ real — endpoint woła INNĄ implementację.** API zwracało
  `"parity_shards": 2`, ale wołało ścieżkę legacy (XOR), której własny guard
  odrzucał >1 utratę. **Sprawdź, KTÓRĄ funkcję woła endpoint produkcyjny:**
  `grep -rn '<fn>' runtime/crates/*/src/api.rs`. Często są dwie — nowa (dobra)
  i legacy (używana), a deklaracja pochodzi z nowej.
- **Trim/padding bez `length` = cicha korupcja danych binarnych.**
  `reed_solomon_heal` ucinał końcowe zera (`while last==0 { pop }`), bo nie
  przechowywał oryginalnej długości → payload binarny kończący się `0x00`
  wracał obcięty. Kontrast: `fec.rs` ma `original_len` w ramce i jest odporny.
  **Reguła: każda rekonstrukcja bez pola długości jest podejrzana o utratę
  danych binarnych.**

**Harness zdolności (wzorzec reprodukowalny):** payload deterministyczny,
niezerowy, długość NIE-wielokrotność bloku → usuń element, o którym mówi
obietnica (dane, nie parity) → odtwórz → `assert_eq!` z oryginałem → dodaj
przypadek poza tolerancją (MUSI błąd, nie śmieci) → dodaj granicę rozmiaru
(1B, 2B, trailing-zero). Pełny szkielet + tabela zmierzonych ścieżek RS:
`references/advertised-capability-vs-real-harness.md`.

**Bramka:** deklarowana tolerancja == zmierzona; wynik wklejony do raportu z
surowym `test result: ok. N passed`, nie opisem zamiaru.

## 17. WŁASNY skrypt weryfikacyjny ad-hoc — nie zaszywaj oczekiwanej liczby (2026-10-02)

**Objaw:** piszesz doraźny skrypt bash (`/tmp/hermes-verify-<x>.sh`) sprawdzający
WŁASNĄ zmianę, ogłaszasz `1 FAIL` — a defekt jest **w skrypcie**, nie w kodzie.
W jednej sesji ta sama pomyłka zaszła DWA razy:

1. `grep -qE '^5 0 0$'` na wyniku testu — a testów było **6**, nie 5. Literał
   zaszyty z pamięci → fałszywy FAIL na zielonym.
2. Pętla licząca agentów: `test -f ~/.$a/skills/...` — dla `aigon-code` konstrukcja
   dawała `~/.aigon-code` (NIE istnieje), a realna ścieżka to `~/.aigon/skills/`.
   Wynik `1/7` mimo `7/7` — **błąd konstrukcji ścieżki, nie dostawy**.

Oba razy prawdziwy stan był ZIELONY, a ja zaraportowałem czerwony.

**Reguła — kryterium w skrypcie ad-hoc MUSI pochodzić z POMIARU, nie z pamięci:**

```bash
# ŹLE — zaszyta liczba (rozjedzie się z każdym nowym testem/agentem)
grep -qE '^5 0 0$' wynik.txt

# DOBRZE — najpierw ZMIERZ, potem porównaj z tym samym pomiarem
NEXP=$(grep -c '@Test' Test.kt)                          # ile faktycznie jest
# XML: python3 -c "…parse tests=/failures=/errors=…"      # ile faktycznie przeszło
[ "$tests" = "$NEXP" ] && [ "$failures" = 0 ] || FAIL
```

```bash
# ŹLE — konstrukcja ścieżki na skrótach (mapuje źle na nietypowe nazwy)
for a in qwen … aigon-code …; do test -f ~/.$a/skills/…; done   # ~/.aigon-code ✗

# DOBRZE — iteruj po RZECZYWISTYCH katalogach docelowych, nie po nazwach agentów
for d in ~/.qwen ~/.claude ~/.hermes ~/.grok ~/.aigon ~/.codex ~/.dsh; do …
```

**Zasada:** przy KAŻDYM czerwonym z własnego skryptu ad-hoc **najpierw sprawdź
skrypt** (czy oczekiwanie pochodzi z pomiaru, czy z pamięci), ZANIM nazwiesz to
defektem. To ta sama dyscyplina co „przy każdym CZERWONYM sprawdź detektor" —
tylko detektorem jesteś tu TY, a literał w Twoim skrypcie jest hipotezą.

**Raport, gdy to złapiesz:** popraw skrypt, powtórz, podaj wynik ORAZ
sprostowanie („poprzedni FAIL był w moim skrypcie, nie w kodzie”). Sprostowanie
zapisane w miejscu, gdzie padł fałszywy werdykt — klasa LAW-011.

**Wariant 3 (zmierzony 2026-10-02, ta sama sesja): test ad-hoc odtwarzał NIE TO
ŚRODOWISKO, co produkt.** Sprawdzałem import `src.telemetry` przez
`docker run --rm --entrypoint sh <obraz> -c ...` i dostałem `ModuleNotFoundError`
— ogłosiłem „fix nie działa”. Ale `src/` jest **BIND-MOUNTEM** z compose
(`./src:/opt/monai-bet/src`), którego goły `docker run` NIE ma. Powtórka z
`-v "$PWD/src:/opt/monai-bet/src:ro"` → `IMPORT OK`. Fałszywy czerwony.

**Reguła:** test ad-hoc musi odtwarzać **całe środowisko runtime** (mounty, cwd,
env, user), nie tylko obraz. Zanim ogłosisz defekt: `docker inspect <działający
kontener> --format '{{json .Mounts}}'` i odtwórz te same mounty. To ten sam
wzorzec co pkt 1a („mierzysz nie tę KOPIĘ”) przeniesiony na uruchamianie.

## 18. Cztery nowe tryby fałszywego alarmu zmierzone 2026-10-02 (bramka mierzy nie tę rzecz)

**(a) Bramka porównuje RÓWNOŚĆ ścieżki, gdy kanon dopuszcza PODKATALOG.**
`canonicality-gate.sh` wymagała `working_dir == <workspace>` (dokładnie). Kontenery produktów
mają `working_dir = <workspace>/products/<slug>` albo `<workspace>/core/*` — **podkatalog <workspace>**,
a bramka ogłosiła **34 fałszywe P0** („zbudowany poza PROD"). Fix: `case "$wd" in "$PROD"|"$PROD"/*)`.
Reguła: gdy bramka porównuje ścieżkę, zapytaj **czy kanon dopuszcza prefiks**, nie tylko równość.

**(b) Bramka flaguje STAŁĄ PROTOKOŁU jako „dynamiczną wartość".**
`validate-sot` łapała IP z prefiksów `10.|100.|192.168.|172.16-31.` jako „hardcoded IP".
`<host>/10` (CGNAT RFC6598 = Tailscale) to **stała protokołu**, jak `127.0.0.1` —
nie „dynamiczny IP węzła". Fix: wyjątek. Reguła: prefiks-adres nie dowodzi „ręcznego
utrzymania"; rozstrzygnij, czy wartość jest stałą czy topologią.

**(c) Allowlista wyjątków wskazuje MARTWĄ ścieżkę — wyjątek nie działa.**
`CANONICALITY.yaml` miał `secret_scan_exclude` na `products/vairyfy-saas/...`, a produkt
przemianowany na `products/vairify/...` (bez `y`) → 2 fałszywe P0 na sekret. Reguła: przy
rozjeździe „wyjątek jest, a bramka dalej krzyczy" — **sprawdź `ls` ścieżki wyjątku**, zanim
szukasz winy w kodzie. Allowlisty starzeją się razem z refaktorami nazw.

**(d) Bramka WISI, bo `subprocess` bez timeoutu × N kontenerów.**
`otlp-client-ca-check.sh` wołała `subprocess.run` **bez `timeout=`**, 4× per kontener × 129
kontenerów = ~516 synchronicznych wywołań. Przy load ~3× rdzenie → pre-push TIMEOUT („werdyktu
nie ma = NIE PASS"). Fix: `timeout=10` + **jedno** `docker inspect` (format `env|||image|||user`)
zamiast czterech — 516→129. Reguła: każdy `subprocess` w bramce MUSI mieć timeout; liczba
wywołań zewnętrznych skaluje się z liczbą obiektów.

**Wspólny test rozpoznawczy:** **„czy to, co bramka mierzy, JEST tym, czego kanon wymaga?"**
(równość vs prefiks; stała vs topologia; istniejąca vs martwa ścieżka wyjątku; ograniczone vs
nieograniczone wywołanie zewnętrzne). Zanim „naprawisz" kod pod czerwony — sprawdź bramkę.

## 20. Rejestracja ≠ egzekucja — byt w grafie/kanonie bez bramki to deklaracja (2026-10-02)

**Objaw:** coś JEST zarejestrowane (skill w `skill-graph.yaml`/`exec-graph.yaml`, capability,
kernel w manifescie), więc wygląda na „podpięte" — ale przy pushu/commicie **nic tego nie
mierzy**. Zmierzone: skill `perfect-magic-awesome-quality-gate` był w OBU grafach, ale bez
triggera w `hooks.yaml` i bez bramki — czyli sama rejestracja, zero egzekucji („skille do kanonu,
jeśli nie to musi się dziać automatycznie" — cyt. Suwerena).

**Reguła:** rejestracja (wpis w grafie/manifescie) i egzekucja (bramka + trigger) to DWIE osobne
rzeczy. Dowód „podpięte" = **bramka, która FAILuje przy braku**, nie wpis w pliku. `gate-reachability`
łapie sierotę (bramka bez triggera), ale NIE złapie bytu bez bramki — to trzeba sprawdzić ręcznie.

**Leczenie — wzorzec (reprodukowalny):**
1. Napisz bramkę `tools/gates/<nazwa>.sh` (kontrakt: exit 0=PASS 1=FAIL 2=env).
2. Wpisz jednocześnie w `config/canonical/gates.yaml` (profiles fast/full/release/genesis=BLOCKING)
   **ORAZ** w `config/canonical/hooks.yaml` (trigger, np. `git:pre-commit` = FAST). Brak jednego
   z dwóch = albo sierota (gate-reachability FAIL), albo bramka nigdy się nie odpala.
3. Ad-hoc uruchom (`bash tools/gates/<nazwa>.sh`) i pokaż PASS na realnym stanie.
4. Propaguj plik na aktywne nody (bramka lokalna ≠ na nodach).
5. `chown aigon:aigon` + `chmod 755` po `write_file` (0600 → rc=126 „Brak dostępu").

**Wariant „flaga funkcji" — brak egzekucji zamień w CZERWONĄ bramkę (2026-10-13).**
Najtańsze domknięcie tej samej luki, gdy wpięcie jest jeszcze niegotowe: dodaj
mechanikę jako DANE z `Enabled = false` i strażnika, który **nie pozwoli jej
włączyć bez wpięcia**:

```lua
if Config.X.Enabled then
    check("Enabled=true wymaga wpietego runtime", src:find("Config.X", 1, true) ~= nil)
else
    check("X zadeklarowane, ale WYLACZONE do czasu wpiecia",
        Config.X.Enabled == false and src:find("Config.X", 1, true) == nil)
end
```

Przekręcenie przełącznika bez kodu = FAIL, więc „obietnica bez pokrycia" nie
przechodzi przez bramkę. Wzorzec zmierzony na module ruchu (pojazdy), ale działa
dla każdej flagi `Enabled` w configu — i jest ta sama rodzina co „rejestracja ≠
egzekucja": funkcja może istnieć jako dane tylko wtedy, gdy NIC jej nie udaje
uruchomionej.

## 19. Bramka spójności rejestracji komponentu — projekt i ratchet (2026-10-02)

Gdy komponent istnieje w KILKU rejestrach i nic nie wymusza spójności — bramka tej klasy to
domyka (zmierzone: 12 rozjazdów kerneli — manifest-bez-kodu / crate-bez-manifestu /
crate-bez-rejestracji / rozjazd nazwy; pełny opis w `aigon-kernel-architecture`).

**Wzorzec projektowania (reprodukowalny):**
1. Analiza w `python3 - "$ROOT" <<'__PYNAME__'` — heredoc z UNIKALNYM markerem (NIE `PY` —
   koliduje z `bash -n`; zagnieżdżony `$()` kruchy). Jeden token na linię stdout.
2. Trzy zbiory (plik/crate, manifest, rejestracja w kodzie) → różnice symetryczne w OBU stronach.
3. **Allowlista = znany dług (ratchet)**, `grep -vxF -f allowlist`, wolno TYLKO zmniejszać.
   Nie osłabiaj kryterium, żeby przejść.
4. Wpisz jednocześnie w `gates.yaml` (profiles) ORAZ `hooks.yaml` (trigger) — inaczej
   `gate-reachability` zgłosi sierotę, a bramka nigdy się nie odpali.
5. `chown aigon:aigon` + `chmod 755` po `write_file` (0600 → `Brak dostępu` rc=126).
6. Ad-hoc uruchom i zapisz ZMIERZONE wartości do allowlisty (z pamięci = rozjazd).

**Reguła „wymagaj tyle, ile obiekt realnie potrzebuje".** Druga bramka (`kernel-observability`)
wymaga „komponent z ZEWNĘTRZNYM źródłem MUSI mieć mechanizm raportowania braków". Pierwsza
wersja wymagała tego od WSZYSTKICH 39 → 27 fałszywych FAIL (kerneli czysto-obliczeniowych nie
ma czego „deadmanować"). Za szerokie kryterium = fałszywy czerwony na zdrowej większości.
Uwaga: wzorzec EXTERNAL łapie za szeroko — lokalny `std::fs::read` własnego pliku ≠ źródło
zewnętrzne (zmierzone fałszywe trafienie: `hawking`).

## 21. Bramka mierzy JEDNĄ OŚ, byt ma ICH WIELE — „sierota" bez policzenia WSZYSTKICH ścieżek (2026-10-03)

**Objaw:** bramka pokrycia („czy każdy byt ma ścieżkę wykonania") raportuje sieroty,
ale liczba jest **ZAWYŻONA**, bo mierzy tylko część osi. Wygląda jak realny dług,
a jest błędem pomiaru — i prowadzi do „napraw" triggerów, które wcale nie brakowały.

Zmierzone na `tools/gates/gate-reachability.sh` (`<workspace>`): moduły `gates.yaml`
(106) mają **TRZY niezależne osie wykonania** — `hooks.yaml` (hooki git), `cron.yaml`
(cykliczne) i **profil CI** (`verify.sh gates CI` wołane z `.github/workflows/*.yml`).
Pierwsza wersja rozszerzenia liczyła tylko hooks+cron → **66 „sierot"**. Po dodaniu
trzeciej osi (CI): **0 sierot, 106/106 spiętych**. Rozkład: hooks 69, cron 8, CI 29.

**Reguła:** zanim ogłosisz byt „sierotą/niepodpiętym", **wypisz WSZYSTKIE osie
wykonania w tym systemie** i policz każdą. Sierota = brak **JAKIEJKOLWIEK** ścieżki,
nie brak ścieżki w tej jednej osi, którą akurat bramka zna.

```bash
# Inwentarz osi — pytaj o KAŻDĄ warstwę, nie tylko hooki:
grep -rln 'verify.sh.*gates' .github/workflows/     # oś 3: CI/profil
grep -n  'cyclic:' config/canonical/hooks.yaml      # oś 2: cron (przez hook-runner)
grep -n  'git:pre-commit\|git:pre-push' hooks.yaml  # oś 1: hooki
```

**Rozpoznanie klasy:** bramka ma stałą `ci_only`/`local`/`no_path` i **jedną** z osi
traktuje jako „nieosiągalne" → sprawdź, czy to nie druga oś tego samego bytu.
W tym repo `ci_only=20` to nie „martwe", a „obsługiwane wyłącznie w CI" — bramka to
wie i nazywa poprawnie; rozszerzenie o moduły MUSI użyć tej samej trójoosiowej logiki.

**Pułapka pochodna — ratchet na ZŁEJ liczbie.** Baseline zapisany z zawyżoną liczbą
(66) „chroni" stan, który nigdy nie istniał, i **blokuje** poprawne triggerowanie.
Po korekcie pomiaru **odśwież baseline** (`--update-baseline`) i pokaż przejście
`66 → 0` jako poprawę, nie jako regresję.

**Test negatywny tej bramki (wzorzec):** wstrzyknij samą WARTOŚĆ stanu, nie kopię
skryptu — kopia zmienia `ROOT` (liczy względem `/tmp`) i daje `FAIL` z **innego**
powodu (`brak configu`), co wygląda jak „wykrył regresję", a nim nie jest.
Poprawnie: wyizoluj warunek werdyktu (`NOW > BASE → FAIL`) i przetestuj na danych
brzegowych: `99>0=FAIL, 0<99=PASS, 0=0=PASS`.

**Baseline plik bywa root/aigon-owned** — `write_file`/edycja jako user da
`PermissionError`. Poprawka: `sudo -n python3 ...` + `chown aigon:aigon` po zapisie.

## 22. Nieaktualny przebieg testu = fałszywy czerwony MIĘDZY sesjami (2026-10-03)

**Objaw silniejszy niż pkt 6:** powiadomienie o zakończeniu procesu w tle pokazuje
`8 failed` (lub `7 failed`) w testach, które **już naprawiłem** — a build jest zielony.
Proces **wystartował PRZED zapisaniem poprawek** i rozstrzygnął o starym stanie.

Zmierzone: `gradlew :app:testDebugUnitTest` wystartował ~02:5x, poprawki testów
zapisano 02:43–02:53, a wynik „312 tests completed, 8 failed" dotyczył drzewa
sprzed poprawek. Świeży `--rerun-tasks` na obecnym stanie: **BUILD SUCCESSFUL, 0 FAILED**.

**Reguła — zanim uznasz czerwony z procesu w tle:**
```bash
# mtime wyniku vs mtime edytowanych źródeł — kto jest nowszy?
stat -c '%y' app/build/test-results/**/*.xml      # kiedy policzono
find app/src -name '*.kt' -newer <plik-wyniku>    # co zmieniono PO policzeniu
```
Jeśli źródła są **nowsze** niż wynik → wynik jest **nieważny**, nie jest werdyktem.
Wymuś świeży przebieg (`--rerun-tasks` / `--no-build-cache`) i dopiero jego wynik
cytuj. **Nie broń starego przebiegu i nie „naprawiaj" kodu pod niego** — to ta sama
dyscyplina co pkt 6 (unieważnij, zmierz od nowa, podaj mtime/hash razem z wynikiem).

## 23. Grep po WŁASNYM komentarzu — fałszywy czerwony przy weryfikacji ad-hoc (2026-10-03)

**Objaw:** skrypt ad-hoc sprawdzający Twoją zmianę daje `FAIL` na warunku, który
w kodzie jest spełniony. Przyczyna: `grep` trafił w **komentarz, który SAM dopisałeś**,
cytujący usuwany kod (np. „usunięto `mailto:phoneguard@szamani.ai`" → grep łapie adres).

Zmierzone 2026-10-03, dwa razy w jednej weryfikacji:
- `grep 'mailto:phoneguard@szamani.ai' AuditLogPage.tsx` → trafił w mój komentarz
  opisujący tę naprawę → fałszywy „hardkod nadal jest";
- `grep '"versionName=.*1.0.5"'` → aapt2 wypisuje `versionName='1.0.5'`
  (**apostrof**, nie cudzysłów) → fałszywy „zła wersja", mimo `versionName=1.0.5`.

To rozszerzenie pkt 7 („grep łapie KOMENTARZ, nie kod") na **własne** komentarze
weryfikatora — najpodstępniejszy wariant, bo autor traktuje własny opis jako neutralny.

**Leczenie — detektor MUSI wycinać komentarze i znać format narzędzia:**
```bash
# 1) wycięcie komentarzy PRZED grepem (HTML/Kotlin/TS: <!-- -->, //, /* */)
strip(){ python3 -c "
import re,sys
t=open(sys.argv[1],encoding='utf-8').read()
t=re.sub(r'<!--.*?-->','',t,flags=re.S)
t=re.sub(r'/\*.*?\*/','',t,flags=re.S)
t=re.sub(r'//[^\n]*','',t); sys.stdout.write(t)" \"$1\"; }
strip plik | grep -q 'wzorzec' && FAIL || OK
# 2) format wyjścia narzędzia bierz z POMIARU, nie z pamięci:
aapt2 dump badging app.apk | grep -oE "versionName='[^']*'"   # apostrof!
```
**Reguła:** skrypt ad-hoc ma te same obowiązki co produkcyjna bramka — parsuj
**STRUKTURĘ/format rzeczywisty**, nie tekst pliku. Gdy poprawiasz detektor, powtórz
i **podaj sprostowanie** w miejscu fałszywego werdyktu (klasa LAW-011).

**Dodatkowo: nazwa zmiennej `$F`/`$FC` w skrypcie ad-hoc koliduje ze ścieżką pliku.**
Zmierzone: `F=/sciezka/do/pliku` (zmienna na plik) nadpisana licznikiem FAIL →
`[: /sciezka: oczekiwano wyrażenia całkowitego` i `EXIT=2` mimo `13 OK`. Trzymaj
**osobne** nazwy: `SRC` (ścieżka), `NFAIL`/`OK` (liczniki).

## 26. `patch`/`sed` na pliku z POWTARZAJĄCĄ SIĘ strukturą — kotwica nie-unikalna (2026-10-03)

**Objaw:** edycja HTML/XML/YAML, w którym ten sam blok występuje wiele razy
(karty w `<ul>`, sekcje per-język, akapity), kończy się serią
`Found N matches for old_string` (12, 13 trafień) — mimo że **wzorzec wizualnie
wygląda na unikalny**. Trzy nieudane próby z rzędu, każda „podobna".

**Mechanizm:** `patch` działa na **tekście**, a szablon powiela ten sam
fragment (np. każde `<li class="card">…</li>` różni się tylko numerem, ale
ogon `</ul>\n</div>\n</section>` jest identyczny we wszystkich sekcjach).

**Reguła — nie walcz z kotwicą, zmień metodę:**
1. **Zawęź kotwicę do fragmentu, który REALNIE jest unikalny** (numer/ID:
   `<span class="idx">08</span>`), NIE do wspólnego ogona.
2. Gdy nadal nie-unikalna — **przejdź na wstawianie po numerze linii** przez
   `python3` (najpewniejsze dla powtarzalnej struktury):
   ```bash
   python3 - <<'PY'
   p="landing.html"; lines=open(p,encoding="utf-8").read().split("\n")
   i=next(j for j,l in enumerate(lines) if l.strip()=='<section id="coverage">')
   lines[i:i]=["…nowa sekcja…",""]      # wstaw PRZED kotwicą-po-linii
   open(p,"w",encoding="utf-8").write("\n".join(lines))
   PY
   ```
3. **Zanim wybierzesz kotwicę, policz ją:** `grep -c '<ogon>' plik` — jeśli
   > 1, to NIE jest kotwica. `grep -n` na potencjalnym unikacie (ID, numer)
   potwierdza, że jest DOKŁADNIE raz.

**To ten sam obowiązek co cały skill:** sprawdź, czy narzędzie patrzy na
właściwą rzecz (tu: czy kotwica jest unikalna), zanim uznasz „nie da się".
Objaw „`patch` nie działa" jest prawie zawsze objawem „kotwica nie-unikalna".

## 24. Własny skrypt deploy/weryfikacji tworzy SAMOZAPĘTLAJĄCY symlink (2026-10-03)

**Objaw:** `sha256sum <plik>` pada z `Za duże zagnieżdżenie dowiązań symbolicznych`
(ELOOP), a bramka zgodności sum zgłasza FAIL na artefakcie, który **jest** poprawny.
Plik ma **7 bajtów** (albo tyle, ile liczy jego własna nazwa).

**Mechanizm:** skrypt tworzył parę „nazwa treścią + alias latest":

```bash
ln -sf "$APK_NAME" "$LATE"        # OK gdy APK_NAME != APK_LATEST
```

Dla produktu, gdzie `APK_LATEST == APK_NAME` (np. phoneguard: `app.apk` jako obie
role), powstaje `ln -sf app.apk app.apk` → **dowiązanie wskazuje na siebie**.
`readlink -f` zwraca wtedy `ELOOP`, `sha256sum` czyta 7 bajtów ścieżki zamiast
13 MB APK, a porównanie sum „lokalna == A == B" wygląda jak rozjazd deployu.

Zmierzone: bramka publish dla phoneguard — `app.apk` 7 B zamiast 19 047 600 B;
`cp -f` na dowiązanie **nie naprawia** (kopiuje przez dowiązanie).

**Reguła — każdy generator pary alias+wersja MUSI wykluczyć przypadek tożsamości:**

```bash
[ -L "$CEL" ] && rm -f "$CEL"          # cel MUSI być plikiem, nie linkiem
cp -f "$SRC" "$CEL"
if [ "$APK_LATEST" != "$APK_NAME" ]; then
  [ -L "$LATE" ] && rm -f "$LATE"
  ln -sf "$APK_NAME" "$LATE"           # symlink TWÓRZ tylko gdy nazwy RÓŻNE
fi
```

**Test rozpoznawczy** — po każdej publikacji sprawdź, że artefakt jest PLIKIEM,
nie dowiązaniem, i ma sensowny rozmiar:

```bash
stat -c '%s %F' "$PLIK"      # rozmiar > próg i %F == "regular file"
readlink -f "$PLIK" || echo "ELOOP — samozapętlony symlink"
```

To ta sama rodzina co §13 (symlink vs zwykły plik wymagają różnej metody pomiaru):
symlink w ścieżce deployu **udaje sukces**, dopóki ktoś nie policzy jego rozmiaru.

## 25. Artefakt build/ zniknął między pomiarami — RÓWNOLEGŁY agent, nie regresja (2026-10-03)

**Objaw:** własny skrypt ad-hoc mierzy `build/outputs/**/app-release.apk` → „brak
APK", mimo że sekundę wcześniej inny krok tego samego skryptu go wypisał. Wygląda
jak „build nie powstał" albo „ktoś usunął artefakt".

**Mechanizm:** w **współdzielonym drzewie** (`<workspace>`, `/opt/projects`) działa
inny agent, który odpalił `gradle clean` / `cargo clean` **w trakcie** Twojego
przebiegu. Katalog `build/`/`target/` jest efemeryczny i **nie należy do Ciebie**.

Zmierzone: weryfikacja `scripts/build.sh` — krok D wypisał APK (13 322 937 B),
krok F zaraz potem: `build/outputs/apk/release/` **pusty**. Wydany artefakt w
`app/` (poza `build/`) był nietknięty i spójny (release.json == plik == publicznie).

**Reguła — mierz artefakt TRWAŁY, nie efemeryczny:**

| mierz to | NIE mierz tego |
|---|---|
| wydany plik w `app/` / `dist/` / `release/` (dom produktu) | `build/outputs/`, `target/`, `node_modules/.cache` |
| to, co leży na produkcji (`curl`/hash publiczny) | cokolwiek, co inny agent może wyczyścić |
| `release.json` + zgodność SHA | stan katalogu pośredniego |

```bash
# ŹLE — katalog build/ może zniknąć między krokami (cudzy `clean`)
[ -f android/app/build/outputs/apk/release/app-release.apk ] && ok || bad

# DOBRZE — trwały dom wydania + zgodność z SSOT
W=$(ls -t app/<produkt>-<wer>-*.apk 2>/dev/null | head -1)
[ -n "$W" ] && [ "$(sha256sum "$W" | cut -c1-16)" = "$(jq -r .sha256 app/release.json | cut -c1-16)" ] && ok
```

**Test negatywny / dowód braku regresji:** jeśli `build/` zniknął, ale `release.json`
== plik wydany == hash publiczny → **nic się nie stało**; to artefakt pośredni, nie
produkt. Nie „naprawiaj" buildu — powtórz build, jeśli potrzebujesz świeżego APK.

**To NIE jest environment-dependent failure do zapomnienia** — to trwała reguła
pomiaru w repo współdzielonym z innymi agentami: **mierzyć to, co przetrwa cudze
`clean`**. Trzecia oś tej samej rodziny co §21 (wiele osi wykonania) i §22
(nieaktualny przebieg): pytanie „czy to, co mierzę, jest stanem ustalonym i moim?"

## 27. Bramka deploy mierzy W TRAKCIE propagacji — fałszywy FAIL rsync-a (2026-10-03)

**Objaw:** skrypt deploy (`pluskwa-deploy-app.sh`) zaraportował
`latest NIE jest tym buildem: latest=38a588bb… build=aadffbaa…` +
`landing NIE publikuje poprawnego SHA-256` i **WERDYKT: NIEUDANY** — a pomiar
**w stanie ustalonym** pokazał 100% zgodności (50 OK / 0 FAIL) na tych samych
4 źródłach.

**Mechanizm:** bramka sprawdzała symlink `latest` i SHA landingu **zanim rsync
zdążył je zaktualizować na obu ramionach** (A prod + B contabo). Pomiar trafił
w okno przejściowe propagacji — ta sama rodzina co §12 (race w teście bramki)
i §25 (artefakt w ruchu).

**Reguła — NIGDY nie ogłaszaj FAIL-a deployu z jednego pomiaru w trakcie wysyłki.**
Po „FAIL" odczekaj i zmierz PONOWNIE wszystkie źródła; dopiero rozjazd w stanie
USTALONYM = realny defekt. Mierz **tę warstwę, którą widzi klient** (publiczny
curl/hash): jeśli publiczne == release.json == plik, deploy JEST dobry, a FAIL
był pomiarem w ruchu.

## 28. Re-podpisanie TEGO SAMEGO kodu daje INNY SHA256 (2026-10-03)

**Objaw:** po świeżym `assembleRelease` APK ma **inny SHA** niż wydany
(`aadffbaa…` vs `9cdfd30a…`) → wygląda jak „kod się zmienił".

**Mechanizm:** podpis APK niesie **timestamp**; re-podpisanie identycznego kodu
daje inną sumę. Rozstrzygaj **pomiarem, nie paniką**:

```bash
stat -c%s nowy.apk wydany.apk                      # identyczne = ten sam kod
aapt2 dump badging nowy.apk | grep versionName     # + versionCode
```

Zmierzone: oba 13 322 937 B, `versionName=4.0.17`, `versionCode=38` — identyczny
kod, różny SHA przez re-podpis. Publikowany SHA MUSI iść z `release.json` i zgadzać
się z plikiem, który **faktycznie leży na produkcji** — nigdy ze świeżego builda.

## 29. Build zależy od sekretu w ENV — „BUILD FAILED" to nie defekt kodu (2026-10-03)

**Objaw:** `./gradlew :app:assembleRelease` → `BUILD FAILED`,
`KeytoolException: keystore password was incorrect`. Wygląda jak zepsuty
kod/certyfikat — a to **brak hasła w środowisku TEGO procesu**.

**Reguła:** gdy build pada na sekrecie (keystore, token, klucz podpisu), zanim
ogłosisz defekt — sprawdź, czy proces ma zmienną, i użyj kanonicznego wrappera:

```bash
export KS_PASS=$(grep -oP '^storepass=\K.*' ~/.keystores/<prod>.pass)
./gradlew :app:assembleRelease        # wrapper: brak pliku -> JAWNY błąd
```

Trwała reguła: buduj przez wrapper, bo surowe `gradlew` zawsze padnie bez eksportu.

## 30. Zmiana `web/**`/`assets/**` NIE wchodzi do APK bez `--rerun-tasks` (2026-10-03)

**Objaw:** usunąłem GTM z `web/index.html`; `assembleRelease` zrobił rebuild
(GTM=0), ale `assembleDebug` **wziął cache** i APK miał nadal `GTM=2`.

**Mechanizm:** gradle traktuje `assets/` jako task **kopiujący** → `UP-TO-DATE`
 gdy nie widzi zmiany w wejściu.

**Reguła — po zmianie `web/**`/`shared/**`/`assets/**` WERYFIKUJ zawartość APK,
nie sam exit builda:**

```bash
unzip -p app-release.apk assets/web/index.html | grep -c '<szukany-string>'   # 0 = weszło
# gdy niezgodne: ./gradlew :app:assembleRelease --rerun-tasks
```

## 31. Bramka mierzy SUBPROCESY innego agenta — `0 modułów` ≠ „nie działa" (2026-10-03)

**Objaw:** uruchamiam driver (`cyclic-modules-sweep.sh`) bez argumentów →
`modułów: 0` → „mechanizm nie robi nic". Ale **cron woła go z pełną listą 37
modułów w argumencie** (`usage: sweep <module>...`).

**Reguła:** zanim ogłosisz „driver/bramka nic nie robi", przeczytaj **JAK jest
wołana w produkcyjnym triggerze**, nie tylko jak wygląda na Twojej ręce:

```bash
grep -A4 '<nazwa>' config/cron.yaml | grep command   # pełny argv z crona
grep '<nazwa>' /etc/cron.d/aigon-cron                # co odpala scheduler
```

Puste wejście z ręki = nieprawidłowe użycie interfejsu, nie defekt.

## 32. `sqlite3 "database is locked"` — często PRZEJŚCIOWY, nie trwały (2026-10-03)

**Objaw:** bramka raportuje `database is locked (5)` + `-journal` obecny →
wygląda jak trwała blokada/korupcja.

**Mechanizm:** inny proces trzymał **krótkotrwałą transakcję** (rollback journal)
w chwili pomiaru; `-journal` zniknął sekundę później.

**Reguła — zanim ogłosisz „baza zablokowana/uszkodzona":**

```bash
sqlite3 <db> "PRAGMA integrity_check;"   # ok = baza ZDROWA
ls -la <db>-journal                       # brak pliku = transakcja zamknięta
ps aux | grep -i sqlite                   # brak procesu = lock przejściowy
```

Powtórz pomiar. Trwała blokada = żywy proces trzymający lock LUB `-journal` stale
obecny bez procesu. Ta sama dyscyplina co §12: czy mierzę stan ustalony?

## 33. Bramka spójności: ZA WĄSKI REGEX + allowlista, która NIE łapie (2026-10-03)

Dwa defekty tej samej bramki (`tools/gates/kernel-wiring.sh`), zmierzone w jednej sesji.
Oba dają fałszywy CZERWONY, oba są tanie do przeoczenia, bo bramka „działa".

### (a) Regex rejestracji łapie 1 z 4 konwencji → 8/12 fałszywych rozjazdów
Bramka porównuje 3 zbiory: crate na dysku, wpis w manifescie, **rejestracja w kodzie**.
Rejestrację wyciągała JEDNYM wzorcem:
```python
code = set(re.findall(r"aigon_kernel_([a-z_]+)::", src))   # ZA WĄSKO
```
A rejestracja ma **CZWORAKĄ** składnię w tym samym pliku `lib.rs`:
```
aigon_kernel_darwin::DarwinKernel::new()          # (a) crate per kernel
aigon_kernel::hermes::HermesKernel::new()          # (b) moduł w crate bazowym
aigon_resilience::kernel::ResilienceKernel::new()  # (b') moduł ::kernel::
Box::new(TruthKernel::new())                       # (c) import + goła nazwa
```
Wzorzec (a) nie łapał (b), (b'), (c) → **8 z 12 raportowanych rozjazdów było
fałszywych** (kernel „zarejestrowany w kodzie", bramka twierdziła „brak rejestracji").

**Reguła:** przy bramce porównującej „deklaracja vs kod", **wypisz WSZYSTKIE
konwencje zapisu** w realnym pliku, zanim napiszesz regex:
```bash
grep -oE 'aigon_[a-z_]+::[A-Za-z]*Kernel' runtime/crates/aigon-runtime/crates/aigon-runtime/src/lib.rs | sort -u | head -20
```
Trzy pułapki poprawek (zmierzone, każda kolejna iteracja):
1. `aigon_kernel::([a-z_]+?)_kernel::` → daje `kernel_world` gdy moduł to `world_kernel`
   → trzeba **zdjąć prefiks `kernel_`** z wyniku.
2. `aigon_([a-z_]+)::[A-Za-z]*Kernel` → daje `kernel_akceleratory` (bo crate to
   `aigon_kernel_akceleratory`) → **globalna normalizacja**: zdejmij `kernel_` ORAZ
   sufiks `_kernel`, i `discard("kernel")` (crate bazowy nie jest kernelem).
3. Normalizacja MUSI być jedna, po zebraniu wszystkich wzorców — inaczej jeden wzorzec
   dodaje prefiks, a drugi go nie zdejmuje.

### (b) Allowlista nie tłumi, bo `  ` (wcięcie) vs brak wcięcia
Bramka drukuje naruszenia z wcięciem (`  KLASA nazwa` — format czytelny), a allowlista
(`kernel-wiring-allowlist.txt`) ma je **bez** wcięcia. Filtr:
```bash
OUT=$(printf '%s\n' "$OUT" | grep -vxF -f <(grep -vE '^\s*#|^\s*$' "$ALLOW"))
```
`grep -vxF` wymaga **DOKŁADNEGO** dopasowania całej linii → `  KLASA` ≠ `KLASA` →
**allowlista nie tłumiła NICZEGO**, bramka FAIL mimo poprawnie wypełnionej listy.
Fix: trymuj wcięcie PO OBU STRONACH:
```bash
OUT=$(printf '%s\n' "$OUT" | sed 's/^[[:space:]]*//' \
      | grep -vxF -f <(sed 's/^[[:space:]]*//' "$ALLOW" | grep -vE '^\s*#|^\s*$') || true)
```

**Diagnoza (gdy allowlista „nie działa"):** porównaj bajt w bajt linie z outputu
bramki i z allowlisty:
```bash
bash tools/gates/<b>.sh 2>&1 | head -1 | cat -A          # tu zobaczysz wcięcie
grep '^<KLASA>' tools/gates/<b>-allowlist.txt | cat -A    # tu nie ma
```

**Zasada łączna (§19 + §33):** allowlista to RATCHET na ZNANYM DŁUGU. Gdy bramka
„nie tłumi", zanim zwiększysz allowlistę — sprawdź (1) czy regex łapie wszystkie
konwencje (inaczej zapisujesz FAŁSZYWE pozycje jako dług), (2) czy filtr dopasowuje
bajt-w-bajt. Allowlista pełna fałszywek „chroni" stan, który nigdy nie istniał i
blokuje poprawne triggerowanie (ta sama pułapka co §21 baseline).

## 35. Detektor liczy WSZYSTKIE elementy TYPU zamiast PODZBIORU kontraktu (2026-10-12)

**Objaw:** bramka „strona renderuje 4 plany map inline" liczyła
`<img src="/…">` — wystąpienia WSZYSTKICH obrazów. Po dodaniu LEGALNEJ galerii
art (hero, portrety, emblematy, wideo) liczba wzrosła `4 → 21` → FAŁSZYWY FAIL
na zdrowej, poprawnie rozbudowanej stronie. Rodzeństwo §18/§21, ale w drugą
stronę: nie „za wąsko", tylko „za szeroko".

**Reguła — mierz PODZBIÓR, którego dotyczy kontrakt, nie wszystkie elementy
pasujące do regexu:**
```python
imgs = re.findall(r'<img src="/([^"]+)"', page)
_gkeys = {n for n, _ in sp.GALLERY}            # KONTRAKT: tylko plany map
plan = [i for i in imgs if i in _gkeys]
check("4 plany inline", len(plan) == 4, plan)  # NIE len(imgs)
```
Ta sama klasa co „porównanie literału na wyjściu narzędzia": kryterium jest
zbiorem ZNANYM Z KONTRAKTU, nie liczbą „czegokolwiek pasującego do wzorca".
Gdy guard mierzy „wszystko, co pasuje", każda nowa funkcja tego samego TYPU go
zapala — a autor wtedy fałszywie „naprawia" KOD zamiast bramkę. (Dokładnie ta
pułapka, przed którą ostrzega C5 w tym samym pliku: mierzenie stałej, nie dostawy.)

## 40. PARAMETR-FIKCJA: test asertował STAŁĄ, a maszyna ją IGNOROWAŁA (2026-10-13)

**Objaw (cichszy od §37):** parametr istnieje w konfigu, ma opis, ma nawet test
asertujący jego wartość — a kod, który powinien go respektować, ma zachowanie
**zahardkodowane**. Wszystko świeci na zielono, bo test pilnuje STAŁEJ, nie logiki.
Zmiana wartości nic nie zmienia i nikt tego nie zauważy.

Zmierzone (`Intro.ClicksPerStep`, projekt miki): stała = `2`, test asertował
`Intro.ClicksPerStep == 2`, a funkcja `Intro.click` miała **dwie fazy `armed` na
sztywno** — nigdy nie czytała tej stałej. Próba zmiany 2 → 1 (UX: 16 klików przed
grą to za dużo dla 10-latka) **nie zmieniła zachowania ani o jeden klik**;
ujawniło to dopiero przepisanie maszyny na licznik (`clicksInStep >= ClicksPerStep`).

**Reguła — dla każdej stałej, którą test asertuje, udowodnij, że KONSUMENT ją
respektuje:**

```lua
-- ŹLE: test pilnuje stałej (przechodzi na zielono i nie mierzy niczego)
check("kontrakt: 2 kliknięcia na krok", Intro.ClicksPerStep == 2)

-- DOBRZE: test mierzy ZACHOWANIE, a stałą bierze jako parametr
local P = Intro.ClicksPerStep
local st = Intro.new(nil)
for _ = 1, P - 1 do assert(Intro.click(st) == Intro.ARMED) end   -- P-1 klików = tylko podświetlenie
assert(Intro.click(st) == Intro.ADVANCE)                          -- P-ty klik = krok dalej
```

Test napisany w ten sposób przechodzi dla `P = 1` i `P = 2` — czyli **mierzy
umowę, nie wartość** i sam wykryje parametry-fikcje (nie przejdzie, jeśli kod
ignoruje stałą).

**Jak szukać tej klasy w audycie (jedno przejście po configu):**
1. dla każdego pola konfigu znajdź plik, który je **CZYTA** (nie: „występuje razem
   w linii") — brak konsumenta to klasa §36/§37, nie §40;
2. dla każdej stałej asertowanej przez test **odwróć wartość i sprawdź, czy wynik
   ZACHOWANIA się zmienia** — jeśli nie, test pilnował stałej; to jest właśnie §40;
3. popraw KOD (maszyna ma czytać parametr), a potem test (ma mierzyć zachowanie).

Zmierzone rodzeństwo tej samej sesji (wszystkie „jest w configu, nikt nie czyta"):
`Config.WorldStory.Title` w payloadzie bez konsumenta w kliencie; pola pasywek
bohaterów (4 z 6 nie miały zastosowania — działała tylko prędkość); atrybut
`biome` ustawiany na każdej bryle spawnu i nigdy nieczytany; `boss_charge`
emitowany przez logikę i nienarysowany (patrz §38b — brak literału w dyspozytorze).

**Stała asertowana przez test i ignorowana przez maszynę jest GORSZA niż jej brak**
— brak zmusiłby do decyzji, a fikcja daje zielone światło i pozór spiętego systemu.

## 41. Strażnik NEUTRALIZUJE SIĘ WŁASNĄ MASZYNERIĄ — dwa tryby (2026-10-13)

Trzecia rodzina obok §39 (zły niezmiennik) i pkt „Detektor zawsze-OK": strażnik
jest napisany poprawnie, ale **jego własny mechanizm sprawia, że nie patrzy**.
Oba tryby zmierzone w jednej sesji (projekt miki), oba przechodziły na zielono.

**(a) Wyjątek o ZASIĘGU CAŁEGO PLIKU — strażnik wyłącza się własną dokumentacją.**
Strażnik zakazu cyrylickich homoglifów miał wyjątek: „linia zawierająca
`cyrylica-ok` jest pomijana". Warunek brzmiał `if not data:find("cyrylica%-ok")`
— czyli **cały plik** był pomijany, gdy znacznik wystąpił GDZIEKOLWIEK. Wystarczyło,
że **opis samego strażnika** (dopisany do sekcji CHANGELOG w tej samej sesji)
wspominał znacznik — i strażnik przepuszczał prawdziwą cyrylicę obok, raportując
„czysto". Sprzeczność wykrył niezależny skan (python po kodpointach): „strażnik
mówi czysto, a plik ma znak".

```lua
-- ŹLE: wyjątek na CAŁY plik (dokumentacja strażnika go wyłącza)
if not data:find("cyrylica%-ok") then  ...  end

-- DOBRZE: wyjątek PER-LINIA, znacznik musi stać na POCZĄTKU linii
for line in (data .. "\n"):gmatch("([^\n]*)\n") do
  local exempt = line:find("^%s*" .. "cyrylica%-ok") ~= nil
  if not exempt and hasCyrillic(line) then dirty[#dirty + 1] = path end
end
```

**Reguła:** każdy wyjątek/allowlista ma ZASIĘG i trzeba go nazwać (linia / plik /
wpis) — a wyjątek szerszy niż potrzeba zamienia strażnika w dekorację. Testuj to
**prozą, która znacznik tylko cytuje** („wyjątek to `cyrylica-ok`") — taka linia
MUSI być liczona. Rodzeństwo §33(b) (allowlista nie tłumi przez wcięcie), ale
odwrotne: tam wyjątek nie działał, tu działał ZA SZEROKO.

**(b) Sonda zapisana konstrukcją, której język NIE ZNA → samokontrola kłamie.**
Samokontrola brzmiała `local probe = "Bo\xd0\xb7e"` — a **Lua 5.1 nie ma escape
`\xNN`** (doszedł w 5.2). Probe stał się czterema znakami tekstu, więc
`hasCyrillic(probe)` zwracało `false` → samokontrola „wykrywa cyrylicę" padała na
POPRAWNYM detektorze (fałszywy czerwony), a „naprawa" przez poluzowanie asercji
dałaby fałszywe zielone.

```lua
local probe = "Bo" .. string.char(0xd0, 0xb7) .. "e"   -- bajty wprost, bez escape
assert(hasCyrillic(probe) == true)                      -- samokontrola MUSI widzieć
assert(hasCyrillic("Zażółć gęślą jaźń") == false)       -- i NIE widzieć polskiego
```

**Reguła:** samokontrola ma dwa obowiązki — **wykryć** zły input i **nie wykryć**
dobrego. Probe buduj konstrukcją, którą język na pewno zna (`string.char`,
`printf`), nigdy „sprytnym" escape'em; brak trafienia na probe diagnozuj najpierw
jako błąd PROBE, nie detektora (§17).

**(c) Potok mutujący stan PRZED bramką — widmowe wydanie.** Skrypt wydania podbijał
wersję i prependował CHANGELOG (kroki 0–1), a bramkę uruchamiał jako krok 2.
Czerwony build zostawiał więc w repo **podbitą wersję i sekcję opisującą wydanie,
którego nie ma** (zmierzone: „widmowe 0.16.0" bez artefaktu — trzeba to było ręcznie
znaleźć i usunąć, a kolejne wydanie miało numer o jeden za daleko).
**Reguła: w każdym potoku bramka idzie PIERWSZA — przed jakąkolwiek mutacją stanu
trwałego** (wersja, changelog, tag, wpis do rejestru). Czerwony build = zero śladu.
Rodzeństwo §25/§27: stan musi być USTALONY, zanim wydasz werdykt albo zapiszesz skutek.

## 42. ARGUMENT TEKSTOWY PRZECHODZI PRZEZ POWŁOKĘ — treść staje się KODEM (2026-10-13)

**Trzy zmierzone warianty jednej klasy: tekst, który zamierzałeś PRZEKAZAĆ, został
wykonany albo zjedzony przez warstwę interpretującą.** Wszystkie wyglądają jak
„narzędzie nie działa", a są błędem konstrukcji argumentu.

**(a) Backticki w argumencie CLI wykonują się jako polecenia — treść ZNIKA.**
Zmierzone: nota wydania przekazana do skryptu jako argument miała w tekście
backticki wokół identyfikatorów (Weapons.new, payAwarded). Powłoka wywołująca
wykonała je, więc do CHANGELOG trafiło `6. argument  dostawał  (notowanie
zdarzenia)` — **bez nazw**, a w paczce wylądował zniekształcony opis. Objaw
rozpoznawczy: puste miejsca tam, gdzie miały być nazwy/ścieżki, plus komunikaty
typu `X: nie znaleziono polecenia`.

```bash
# ŹLE — backticki i podstawienia w argumencie są wykonywane przez powłokę
bash scripts/release.sh patch "naprawione: `payAwarded` zamiast `progressionNote`"

# DOBRZE — nazwy bez backticków, a DŁUGI tekst przez plik:
bash scripts/release.sh patch "naprawione: payAwarded zamiast progressionNote"
bash scripts/release.sh --note-file /tmp/nota.txt      # gdy nota ma > kilku linii
```

**Reguła:** argumentu z nazwami technicznymi **nie owijaj backtickami** (powłoka je
zje), a długie noty przekazuj **plikiem** — dodaj `--note-file`, to tańsze niż
pilnowanie cudzysłowów przy każdym wydaniu.

**(b) Strażnik postawiony NA TEJ SAMEJ WARSTWIE też jest kodem — i odrzuca własny opis.**
Po (a) dodałem strażnik „odrzuć notę ze śladem podstawienia powłoki". Kolejna nota
**została odrzucona, bo OPISYWAŁA ten zakaz** (cytat markera w treści). Ta sama
pułapka co §41(a) (wyjątek o zasięgu całego pliku): strażnik pisany przeciw
artefaktowi, który sam opisujesz, musi **nie** matchować własnej dokumentacji.
Opisuj marker **opisowo** („komunikat powłoki o braku polecenia"), nigdy nie cytuj
go dosłownie w treści przepuszczanej przez ten sam strażnik — albo zrób wyjątek
**per-linia**.

**(c) Ten sam strażnik stał ZA mutacją stanu — zostawił ślad po odrzuceniu.**
Strażnik noty był w kroku 1 (po podbiciu wersji), więc odrzucenie noty zostawiło
**podbity numer bez artefaktu** (drugi raz klasa §41(c)). Kolejność obowiązkowa:
**wszystkie walidacje wejścia PRZED pierwszą mutacją** (wersja, changelog, tag,
wpis do rejestru). Weryfikuj pomiarem, nie lekturą:

```bash
grep -n '0b/8 strażnik' scripts/release.sh | cut -d: -f1          # linia strażnika
grep -n 'echo "\$NEW" > VERSION' scripts/release.sh | cut -d: -f1  # linia mutacji
# i dowód zachowaniem: odrzucona nota => VERSION bez zmian
B=$(cat VERSION); bash scripts/release.sh patch "nota: command not found"
[ "$(cat VERSION)" = "$B" ] && echo OK
```

### 42d. WZORCE REGEX MIĘDZY JĘZYKAMI — cztery zmierzone defekty własnego detektora

Gdy Twój skrypt jest w jednym języku, a wzorzec jedzie przez drugi, detektor potrafi
mierzyć NIC. W jednej sesji trafiłem to **cztery razy** (dwa fałszywe czerwone, dwa
fałszywe zielone), a objaw wyglądał jak defekt produktu:

| Konstrukcja | Co się dzieje | Poprawnie |
|---|---|---|
| `io.popen("grep 'a\\|b' …")` w Lua | Lua **gubi backslash**, BRE widzi `a\|b` jako LITERAŁ → 0 trafień → „wszystko nieemitowane" | `grep -rnE 'a\|b'` (ERE, jedna kreska) |
| `line:match([[event%s*==%s*"([%a_]+)"]])` | `[[…]]` w powłoce to **glob nawiasowy** — wzorzec nie dociera do grepa | zwykłe cudzysłowy w stringu Lua |
| `src:gmatch("limb%25%(([%w]+)%25")` | podwójnie zakodowany nawias → 0 elementów → „bogus=0, OK" (**fałszywe zielone**) | `'limb%("([%w]+)"'` |
| `rsrc:match("…%(.-%nend")` | **Lua 5.1 nie ma `%n`** → `nil` → asercja mierzy nic | wycięcie po indeksie: `sub(start, start + 400)` |

Dwie reguły, które to zamykają:

1. **Wzorzec buduj w TYM języku, w którym go użyjesz.** Do grepa — statyczny string
   w cudzysłowach (bez `[[ ]]`, bez `\|`); do patternu Lua — escapy Lua 5.1
   (`%`, nie `\xNN`, nie `%n`).
2. **Detektor, który zwraca ZERO elementów, jest podejrzany, nie „czysty".**
   Pusty zbiór wejściowy (0 plików, 0 trafień, 0 elementów) prawie zawsze znaczy
   zepsuty wzorzec: daje fałszywe zielone („brak sierot") albo fałszywy czerwony
   („wszystko bez konsumenta"). **Przerwij pomiar**, zanim wydasz werdykt.

**Wspólna zasada:** po każdym CZERWONYM i po każdym **podejrzanie czystym** wyniku
z własnego skryptu — zmierz to samo INNYM narzędziem (python, `grep` z ręki,
`string.char`) ZANIM nazwiesz defekt produktu, i zapisz sprostowanie tam, gdzie
padł fałszywy werdykt (§17, LAW-011).

## 43. Trwały profil gracza: NORMALIZATOR Z BIAŁĄ LISTĄ + ZAPIS NA WYBRANYCH POLACH (2026-10-13)

**Objaw:** gracz kupuje przedmiot za walutę albo dostaje go z łupu i **traci go
przy następnym wczytaniu** — bez żadnego błędu w logu. Testy zielone, bo mierzą
„pole istnieje", nie „pozycja przechodzi round-trip".

**Dwa defekty, które chodzą parami (zmierzone w jednym module):**
1. **Normalizator profilu z hardkodowaną białą listą** przepuszczał tylko dwa
   klucze wpisane na sztywno (`unlocks = { shotgun_basic = ..., rifle_basic = ... }`)
   → każda inna kupiona/zdobyta pozycja była **kasowana przy wczytaniu**.
2. **„Dirty check" zapisu składany z ręcznej listy pól** → zmiana, której nie ma
   na tej liście (odblokowanie bez zmiany monet), nie zaznaczała profilu jako
   zmienionego → **zapis pomijany**, nagroda przepada po sesji.

**Reguły:**
- Normalizator danych gracza **nie zawiera listy „znanych" identyfikatorów** —
  zachowuje KAŻDĄ sensowną pozycję (walidując typ/długość klucza i limit liczby),
  a jeśli ogranicza zbiór, to buduje go z KATALOGU, nie z literałów.
- „Czy zapisać" **nie jest** koniunkcją wybranych pól — to porównanie CAŁEGO
  rekordu przez jedną czystą funkcję (`unlocksEqual(a, b)`), testowalną bez silnika.

**Strażnik (kwintesencja):** round-trip **całego katalogu** przez normalizator —
`for id in pairs(Config.Weapons) do assert(norm.unlocks[id] == true) end` — plus:
śmieci odpadają (fałsz/liczba/klucz liczbowy/pusty/za długi), limit działa
(200 → ≤ 64), a porównywarka widzi zmianę w KAŻDYM elemencie. Wpięty do bramki
jako jeden zestaw na klasę. Pełny zapis z kodem, dowodem offline (`dofile` na
czystych modułach) i sygnaturami rozpoznawczymi:
`references/persisted-player-data-roundtrip.md`.

**Pułapka dowodu (fałszywy czerwony):** dowód offline musi odtwarzać ścieżkę
PRODUKCYJNĄ. Zmierzone: `inventory(..., nil)` (bez bohatera) pokazało „nie da się
wybrać broni", a produkcja zawsze ma wybranego bohatera — mierzyłem nie tę rolę.

## Autorstwo strażnika

- Porównania rób na WYJŚCIU narzędzia, nie na jego kodzie źródłowym.
- Nie porównuj literałów, które narzędzie może przeformatować.
- Strażnik w katalogu, którego runner NIE odwiedza, nie jest strażnikiem.
- Po edycji SKILL.md zweryfikuj `skill_view`: jeśli output urósł
  nieproporcjonalnie, duplikujesz (pułapka `replace_all` — patrz referencja).

## references/

- `references/persisted-player-data-roundtrip.md` — trwały profil gracza (§43):
  normalizator z białą listą kasujący kupione pozycje + „dirty check" na wybranych
  polach; strażnik round-trip całego katalogu, dowód offline przez `dofile`
  (2026-10-13).
- `references/advertised-capability-vs-real-harness.md` — obietnica zdolności
  (tolerancja utrat, FEC, rekonstrukcja) vs pomiar zdolności: wzorzec harnessa
  byte-exact, trzy warianty rozjazdu (słaba asercja / zła implementacja /
  brak `length`), tabela zmierzonych ścieżek Reed-Solomon (2026-10-01).
- `references/gate-falsy-green-modes.md` — sześć trybów porażki bramki
  pomiarowej z kodem i leczeniem (2026-09-29), w tym pułapka `replace_all`
  przy edycji skilli.
- `references/law-falsifiability-enforcement-design.md` — falsyfikowalna
  egzekucja praw/reguł: reguła anty-tautologiczna, kontrakt
  fitness_cmd+mutate_cmd+expect_exit, meta-harness, 5 zmierzonych luk
  (2026-09-29).
- `references/false-fail-detectors-and-mutation-harness.md`,
  `references/negative-tests-and-false-fails.md`,
  `references/negative-test-via-monkeypatch.md` — testy negatywne i fałszywe FAIL-e.
- `references/file-permission-silent-failure.md` — strażnik/generator metryki,
  który **cicho nie ustawia właściciela/praw** artefaktu (chmod jako nie-root na
  pliku root-owned zawsze zawodzi, `|| true` to maskuje). Trzy warstwy pułapki,
  sygnatura rozpoznawcza (`664 root:root` = chown OK / chmod NIE), gotowy blok
  root/nie-root. Plus: `pgrep -f` łapący własną komendę, ładowanie nieistniejącej
  biblioteki (`[ -r ] && .` → FALSE GATE) i rozjazd budżetów czasu (2026-09-30).
- `scripts/skill-registry-integrity.py` — bramka wieloźródłowa (duplikat nazwy,
  kanon ⊇ agent, manifest == rejestracja); `--root` do dowodu w izolacji.

---
## SCALONE z verification-guard-integrity/SKILL.md (2026-09-30) — 8 sekcji, których nie było w wersji bazowej

## Zasada nadrzędna (kanon Suwerena)
> **FAŁSZYWY SUKCES = błąd krytyczny.** „Lepszy brak niż coś zielonego, co nie
> działa." Brak potwierdzenia → `unverified` + `exit 1`. Test negatywny
> obowiązkowy. `NOT_RUN ≠ PASSED`.

Werdykt wolno ogłosić dopiero, gdy masz **trzy** rzeczy:
1. **tożsamość pomiaru** — wiesz, KTÓRĄ kopię / KTÓRY adres / KTÓRĄ rolę mierzysz,
2. **semantykę progu** — wiesz, co dokładnie znaczy FAIL, a co WARN w tym sprawdzianie,
3. **sprawdzian, który umie FAILować** — dowiedzione testem negatywnym, nie założone.

Brak któregokolwiek = werdykt jest hipotezą, nie pomiarem.

## 1. Tożsamość pomiaru — trzy pułapki, wszystkie realnie trafione
### 1a. Mierzysz NIE TĘ KOPIĘ
Ten sam artefakt często istnieje w kilku miejscach i **edytowane ≠ serwowane**.
- Skille: `skill_manage` pisze **kopię agenta** (`~/.hermes/skills/...`), a manifest
  i rejestr wskazują na **SSOT** (`skills/shared/<name>/`). Zmierzone 2026-09-28:
  **285 z 798** skilli miało rozjazd, a bogatsza była zwykle kopia AGENTA
  (×2,2 … ×4,4), czyli SSOT serwował stub.
- Zanim uznasz coś za „wdrożone", sprawdź rozmiar/hash OBIE kopie i **co zwraca
  rejestr** (`length(content)`, `source_path`), nie co edytowałeś.

### 1b. Mierzysz NIE TEN ADRES
- „Port nasłuchuje" ≠ „ruch idzie tam". Kolektor OTLP słuchał **tylko** na adresie
  Tailscale z TLS, a bramka wysyłała span na `http://127.0.0.1:44318` → `HTTP 000`.
  Wniosek: `ss -ltn` czytaj z **adresem**, nie po samym numerze portu.
- `grep ':PORT'` łapie też linię `<host>:POR` — wtedy „loopback nasłuchuje"
  jest fałszem. Sprawdzaj wzorzec adresu, nie goły port.

### 1c. Mierzysz NIE TĘ ROLĘ
Równość dwóch wartości to kontrakt **tylko** wtedy, gdy obie pełnią tę samą rolę.
Wartość z SSOT równa wartości z renderu innego konsumenta = przypadek, nie dowód.
Nazwij role obu stron, zanim porównasz.

## 2. Semantyka progu — zanim nazwiesz coś „niestałym"
Zdarzenie: bramka `kernel-health` dała FAIL w pre-push **dwa razy**, a ręcznie
`CERTIFICATION: PASS`. Pierwsza diagnoza — „niestała bramka z oknem świeżości" —
była **BŁĘDNA**, i została już wpisana do skilla. Dopiero przeczytanie kodu
rozstrzygnęło: nieświeży pomiar → **WARN** („świeży scrap rozstrzyga, nie FAIL");
FAIL leci wyłącznie przy **świeżej** próbce z `healthy < total`. Pętla 24 przebiegów:
`FAIL=0`, a rozkład stanów pokazał `35/35 healthy, 0 degraded`. Czyli bramka
złapała **realny, chwilowy niedobór** — system się podniósł.

Procedura (kolejność obowiązkowa):
1. **Przeczytaj gałąź decyzyjną** `FAIL` vs `WARN` w kodzie sprawdzianu — to jedyne
   źródło prawdy o tym, co ten werdykt znaczy.
2. **Odtwórz pętlą** (N≥20 przebiegów z timestampem), zamiast wnioskować z dwóch prób.
3. Jeśli FAIL się powtarza — **wskaż KTÓRY element** pada (węzeł, plik, kanał),
   bo „bramka pada" nie jest diagnozą.
4. Jeśli FAIL był przejściowy i nie odtwarza się — to był **realny stan przejściowy**
   (restart, niedobór), nie kłamstwo bramki. Ponów operację, nie „naprawiaj" systemu.
5. **Jeśli opublikowałeś błędną diagnozę (commit, skill, komentarz) — cofnij ją
   w tym samym artefakcie.** Fałszywa diagnoza w skillu krąży dalej i jest gorsza
   niż brak diagnozy (klasa LAW-011: mechanizm, który kłamie).

## 3. Autorstwo strażnika — tak, żeby nie mógł dać fałszywego zielonego
Własny strażnik tej klasy **sam dał fałszywy zielony** i został złapany tylko
dlatego, że napisano do niego test negatywny. Wzorce:

- **Nie porównuj wyjścia narzędzia literałem, które może się skleić.**
  `curl -w '%{http_code}' ... || echo 000` przy nieudanym połączeniu daje `000`
  z curl i `000` z fallbacku → `000000`. Warunek `[ "$C" = "000" ]` tego nie łapie
  i strażnik ogłasza PASS na MARTWYM torze.
  **Rób tak:** `case "$CODE" in 2*|3*|4*) ok ;; *) bad ;; esac`.
- **`401`/`403` = usługa ŻYJE. Kontrakt `== 200` ogłasza zdrową usługę martwą**
  (zmierzone 2026-09-30, bramka `ha-failover`). Bramka sprawdzała „czy kanał
  agenta odpowiada" przez `[ "$before" = 200 ]`. `/mcp` na tej samej, SPRAWNEJ
  usłudze zwracał raz `401` (wymaga auth/nagłówków), raz `200` → bramka wydała
  TRZY fałszywe werdykty: `FAIL kanal agenta nie odpowiada PRZED testem
  (HTTP 401)` oraz `backend NIE wrocil po tescie` — przy kontenerze
  `Up (healthy)`.

  **Reguła — kryterium ŻYWOTNOŚCI, nie kodu sukcesu:**
  ```bash
  # ZYJE = cokolwiek poza {000 (brak polaczenia), 5xx (blad serwera)}
  case "$CODE" in 000|5*) return 1 ;; *) return 0 ;; esac
  ```
  `401`/`403` dowodzi, że **LB ORAZ backend odpowiedziały** (usługa żyje, tylko
  wymaga logowania); brak backendu za LB daje `502/504`, nie `401`. Uwaga na
  fałszywy `000` z curl+fallback (`|| echo 000` skleją się w `000000`) —
  dlatego `case`, nie `[ = ]`.

  **Wniosek dla testów failoveru:** kryterium musi brzmieć *„kanał odpowiada"*,
  nigdy *„kanał zwraca konkretny kod"*. Po naprawie zmierzone: `PASS`,
  replikacja `7/7`, a po ZATRZYMANIU lokalnego backendu kanał **nadal żył**
  (dowód realnego przełączenia na peera).

  **Sprawdź SĄSIEDNIE kryterium tym samym pytaniem** („co tu znaczy sukces?").
  Ta sama bramka miała drugi fałszywy warunek: `SLA` raportowane z liczby PRÓB
  (`REM_MAX`) zamiast z `sla_seconds` z rejestru — wartość poprawna, ale
  **inna rola** (pkt 1c: mierzysz nie tę rolę).
- **Kontrakt progu zapisz jawnie** w komentarzu (np. „2xx/3xx/4xx = osiągalny;
  wszystko inne = FAIL"), żeby następny czytelnik nie zgadywał.
- **Fail-closed:** padnięta zależność = `FAIL` z powodem, nigdy cichy `skip`.
  „Nie mogłem zmierzyć" nie może wyglądać jak „jest dobrze".
- **Test negatywny obowiązkowy:** zmutuj obiekt (wstaw z powrotem zły adres/wartość
  do KOPII) i pokaż, że strażnik krzyczy (`4× FAIL, rc=1`). Bez tego nie wiesz,
  czy strażnik w ogóle patrzy na właściwe miejsce.
- **Umieść strażnika tam, gdzie runner go ODKRYJE.** Zmierzone: katalog
  `tools/gates/tests/` miał 3 testy, których **żaden runner nie uruchamiał**
  (cmentarz). Strażnik w nieodwiedzanym katalogu to dekoracja — sprawdź discovery
  (`tf_discover <kategoria>`) i pokaż dowód uruchomienia (`bash tools/test <suite>`).
- **Nie duplikuj:** jeśli już jest runner i konwencja (`tests/<kategoria>/*.test.sh`,
  `tf_*`, `tf_exit`), dostosuj się do niej zamiast dokładać drugi mechanizm.
- **Strażnik musi być w historii gita.** Bramki integralności sprawdzają istnienie
  pliku na dysku, nie w indeksie — `?? untracked` przechodzi i praca ginie.

## 4. Czego NIE robić (sprawdzone kosztem czasu)
- Nie ogłaszaj „flaky" bez przeczytania progu i pętli odtwarzającej.
- Nie „naprawiaj" systemu pod FAIL, którego nie umiesz odtworzyć.
- Nie promuj/nie uzgadniaj artefaktów **wsadowo** (285 skilli), jeśli kierunek bywa
  różny — rozliczaj per element, z **dowodem podzbioru** (0 linii istnieje tylko
  w kopii, którą chcesz nadpisać), i zostaw niejednoznaczne przypadki właścicielowi.
- Nie mierz jako root/na innej ścieżce, jeśli konsument to zwykły użytkownik:
  `ssh` lądujący jako root sprawia, że `~/.hermes` = `/root/...` — fałszywe „BRAK".

## 5. Uzgadnianie rozjazdu kopii artefaktu (z dowodem podzbioru)
Gdy pomiar (pkt 1a) wykaże, że serwowana kopia to stub, **nie nadpisuj na wyczucie**.
Kierunek bywa różny — zdarzają się artefakty, gdzie bogatszy jest SSOT.

1. **Autorytet ustal pomiarem**: co zwraca rejestr/konsument (`length(content)`,
   `source_path`, rozmiar pliku, liczba plików) — nie to, co „wygląda nowsze".
2. **Dowód podzbioru** — zanim cokolwiek nadpiszesz:
   ```bash
   diff <(sort -u <kopia-do-nadpisania>) <(sort -u <kopia-bogata>) | grep -c '^<'
   # 0 = nic nie ginie (stub ⊂ bogata). >0 = najpierw scal te linie ręcznie.
   ```
3. **Kopiuj, nie symlinkuj** (`cp -a <bogata>/. <cel>/`), potem własność i prawa
   (`chown -R`, `chmod -R a+rX`) — inaczej czytelnik-konsument padnie.
4. **Domknij łańcuch** kanonicznym przebiegiem (`./scripts/skills-ingest-cron.sh`)
   i pokaż dowód końcowy: rozmiar treści w rejestrze **przed → po**.
5. **Nie rób tego wsadowo** dla setek artefaktów — rozliczaj per element, z dowodem
   podzbioru; niejednoznaczne przypadki oddaj właścicielowi.

Uwaga na narzędzie „promocji": w AIGON `skills-ingest.py --promote` **z założenia nie
nadpisuje** istniejących katalogów w `shared` — dołoży brakujący artefakt, ale NIE
naprawi rozjazdu istniejącego. Rozjazd naprawia się świadomą kopią (pkt 3).

Zmierzone 2026-09-28: **285 z 798** skilli miało rozjazd SSOT ↔ kopia agenta, a
bogatsza była zwykle kopia AGENTA (×2,2 … ×4,4). Przyczyna jest mechaniczna:
`skill_manage` pisze kopię agenta, a nic nie promuje jej z powrotem do SSOT.
Skan gotowy do uruchomienia: `scripts/scan-ssot-vs-agent-copy-drift.sh`
(read-only, raportuje per artefakt: rozmiar SSOT vs kopia, liczba plików, kierunek).

## Materiały
- `references/mesh-duty-span-and-kernel-health.md` — pełny, zmierzony zapis dwóch
  przypadków z tej klasy (span prawa OTLP `000000` → `200` + dowód w Tempo;
  FAIL-vs-WARN w `kernel-health`), wraz z komendami pomiarowymi i sekwencją
  „bramka → push w tym samym oknie".
- `scripts/scan-ssot-vs-agent-copy-drift.sh` — sonda rozjazdu SSOT ↔ kopia agenta
  (read-only; wypisuje też komendy dowodu podzbioru i odczytu autorytetu rejestru).

## Przywilej czasowy MUSI mieć `expires_at` (zmierzone 2026-09-29)
Strażnik (guard) dający ROZSZERZONY dostęp musi mieć **datę wygaśnięcia i samo-powrót**
— inaczej „tymczasowe" staje się cichym, trwałym przywilejem, którego nikt nie cofnie.

- Zmierzony wzorzec (kanon Suwerena): **PIN SMS jednorazowy + okno 60 min** z `expires_at`
  i automatycznym powrotem guardrails (cron `enforce` co minutę). Odwraca to wcześniejszy
  model „włącznik awaryjny, nie resetować".
- Realizacja: `scripts/owner-guardrails-window.py` + cron `enforce`.
- **Test strażnika:** nie tylko „czy blokuje", ale też **„czy sam wraca do stanu
  bezpiecznego po wygaśnięciu"**. Brak testu powrotu = strażnik przechodzi na zielono,
  a przywilej wisi w nieskończoność.
- Ta sama klasa co reszta skilla: strażnik, który **mierzy tylko jedną stronę kontraktu**
  (wejście bez wyjścia), daje fałszywe poczucie kontroli.

## 36. Audyt SIEROT wiringu na poziomie PLIKÓW repo — inna oś niż §21 (2026-10-12)

Klasa „REPO/SIEROTY": które pliki w `scripts/` i `tools/` nie są wołane z NICZEGO.
To inna oś niż §21 (tam: „kto wykonuje TĘ BRAMKĘ"; tu: „kto WOŁA TEN PLIK").

**Najpierw kanoniczny detektor, nie własny od zera.** Repo `<workspace>` ma bramkę
`tools/gates/scripts-wired-check.sh` (`--json`/`--list`; `--regen` PISZE allowlistę —
nie używać w audycie read-only). Skanuje szeroko (cron, hooks, compose, cały
`config/*.yaml|json`, ciała `tools/`+`scripts/`, systemd, `/etc/cron.d`), klasyfikuje
tracked-bez-wpięcia=FAIL vs untracked-WIP=WARN, allowlista = `config/canonical/scripts-orphans.json`.

**Cztery pułapki — każda daje FAŁSZYWY werdykt (zmierzone):**
1. **Inwentarz maskuje → fałszywy ZIELONY.** `config/generated/atlas.generated.yaml`
   to spis WSZYSTKICH plików; wliczony do haystacku sprawia, że „każdy plik jest wired"
   → 0 sierot → PASS na martwym kodzie. **Wyklucz cały `config/generated/`.**
2. **Detektor za wąski na nazwę → fałszywe CZERWONE.** Bramki w `hooks.yaml`/
   `gate-registry.yaml` są wołane **SHORT NAME bez `.sh`** (`law-estop`, nie
   `law-estop.sh`). Dopasowuj **basename ORAZ stem**, inaczej `tools/gates/*` to
   ~15 fałszywych sierot.
3. **Kanał pominięty → fałszywe CZERWONE.** Wołającym bywa `.txt` allowlisty,
   `.github/workflows/`, `Makefile`. Grep repo-wide zanim ogłosisz sierotę — ale
   **wzmianka w `docs/`/`reports/`/`skills/` NIE jest kanałem wołania** (to
   „udokumentowany", nie „wired").
4. **Git baseline kłamie, gdy remote nieosiągalny.** `git ls-remote`/`fetch` →
   `Repository not found` ⇒ `origin/main` = STALE remote-tracking ref, a „ahead/
   behind 4000+" jest bez sensu. Tracked/WIP dziel przez `git ls-tree -r HEAD`
   (NIE `ls-files`).

**Wydajność:** nie `grep -r` po `<workspace>` (timeout na `backups/`+`artifacts/`);
token-set zamiast substring (`name in haystack` = O(n·m), timeout); wykluczaj
`.venv*` **po prefiksie** (`tools/.venv-capability` rozwaliło kandydatów 1446→12215)
oraz `site-packages`, `/lib/py/`, `vendor`.

Pełny runbook + kanoniczne kanały + artefakty SSOT: `references/sieroty-audyt-plikowy.md`.
Gotowa sonda read-only: `scripts/repo-orphan-detect.py [ROOT]`.

## 37. Callback PODŁĄCZONY, ale z ZŁĄ sygnaturą — nazwa jest, przepływ nie (2026-10-13)

**Rodzeństwo §36 i `references/declared-but-unwired-contracts.md`, ale ostrzejsze:**
tam nie ma konsumenta w ogóle; tu konsument JEST w grafie wywołań, zdarzenie jest
emitowane, a mimo to **dane wpadają w zły parametr** i efekt jest zerowy. Każdy
grep i każdy test „czy podłączone" świeci na zielono.

Zmierzone (projekt miki, Luau/Roblox; audyt wypłaty odznak). Produkcja robiła:
`Weapons.new(..., onBadge)` (ServerRuntime.lua:414), a `Weapons` wołał
`self.onBadge(userId, awarded)` — 2. arg = LISTA odznak. Ale przekazany callback
miał **inną sygnaturę**: `progressionNote(userId, event, data)` — traktował 2. arg
jako NAZWĘ zdarzenia. Lista ląduje więc w slocie `event` → `note()` nie dopasowuje
żadnej gałęzi `if event == "..."` → zwraca `{}` → wypłata 0. Odznaka wchodziła do
STANU, ale monety nigdy nie trafiały na portfel (zmierzone: portfel 0 zamiast 20).

**Dlaczego bramka tego nie złapała:** test (`tests/badges.lua`) asertował OBECNOŚĆ
symbolu — `rsrc:find("Weapons%.new%([^)]*progressionNote%s*%)")` — czyli wręcz
**cementował błędne okablowanie**, bo ktoś skopiował je do testu jako wzorzec.

**Reguły rozpoznawcze (wszystkie trzy):**
1. **Asercja na OBECNOŚĆ wywołania ≠ asercja na PRZEPŁYW.** Test ma mierzyć EFEKT
   (saldo portfela / stan po zdarzeniu), nie string w źródle. `find("foo(")` nie
   sprawdza liczby, kolejności ani typów argumentów.
2. **Porównaj sygnaturę DEFINICJI z miejscem WYWOŁANIA.** Gdy callback jest
   przekazywany między modułami, wypisz obie strony: `function Nazwa.new(... onBadge)`
   oraz `self.onBadge(a, b)` i sprawdź, co druga strona robi z każdym argumentem.
   Niezgodny slot = cichy zero-effect.
3. **Bramka asertująca BŁĘDNE okablowanie CEMENTUJE defekt.** Zielony test, który
   utrwala złe wywołanie, jest gorszy od jego braku — następny czytelnik uzna je
   za wzorzec. Gdy to znajdziesz, napraw też test (asercja behawioralna), nie tylko kod.

**Osobny wariant tej samej rodziny (ten sam audyt):** zdarzenie zadeklarowane w
LOGICE, ale nigdy nieemitowane — `core_repair` istnieje w `Progression:note`
(odznaka `caretaker`), a mechaniki naprawy rdzenia nie ma (w produkcji tylko
KOMENTARZ `-- progression:note(..., "core_repair")`). Test wołał zdarzenie WPROST,
omijając nieistniejący przepływ → zielono; miał nawet jawną allowlistę znanych luk
(`allowedKnownGaps = { caretaker = true }`). **Rozróżniaj klasę:** „zła sygnatura"
(przepływ jest, dane giną) vs „brak emisji" (przepływu nie ma).

**Technika dowodu — reprodukcja przepływu produkcyjnego offline (moduły czyste).**
Gdy moduł jest „czysty" (zero API silnika; w Luau/Roblox: bez `Instance`/`workspace`/
`require(script...)`), załaduj PRAWDZIWE moduły przez `dofile` i odtwórz sekwencję
wywołań produkcyjnych poza uruchomieniem gry — bez Studio, bez serwera:

```lua
local Config      = dofile("src/shared/config/Config.lua")
local Progression = dofile("src/server/Progression.lua")
local Rules       = dofile("src/server/GameRules.lua")
-- (1) award — tak jak robi to produkcja, potem przekaż WYNIK do callbacku:
local awarded = prog:note(uid, "kill", { distanceStuds = 150 })  -- przyznaje odznaki
prog:note(uid, awarded)                    -- = onBadge(uid, awarded) w produkcji
print(players[uid].profile.coins)          -- 0 = DOWÓD (oczekiwane 20)
```

Portfel 0 przy oczekiwanym 20 rozstrzyga bez Robloxa. Ten sam wzorzec działa dla
każdej pary „moduł czysty + glue". W raporcie podaj wynik (0 vs 20) razem z
`plik:linia` OBU stron wywołania.

**Audyt „zadeklarowane, ale nigdy nie wypłacane" (metoda):** dla każdej pozycji
rejestru idź drogą `zdarzenie → award → wypłata → magazyn trwały` i sprawdź KAŻDE
ogniwo: (a) czy zdarzenie jest emitowane w `src/` (nie w komentarzu, nie tylko w
teście), (b) czy award trafia do właściwego parametru, (c) czy wypłata jest wołana
na tej samej ścieżce co award. Pozycje „jest w Config, nigdy nie płaci" podaj
tabelą z `plik:linia` dla każdego ogniwa. Pełny zmierzony zapis przypadku (miki
2026-10-13: tabela odznak, oba warianty defektu, skrypt dowodowy, kontekst balansu):
`references/wired-callback-signature-mismatch.md`.

## 38. Strażnik „pokrycia producent↔konsument" — DWA tryby kłamstwa i jedna reguła, która je zamyka (2026-10-13)

Klasa: „każdy X wysyłany/emitowany przez producenta ma konsumenta". Strażnik tej
klasy jest wygodny (grep po źródłach) i dlatego kłamie na dwa sposoby naraz —
zmierzone oba w jednej sesji, na tym samym strażniku:

**(a) Detektor bez ZAKRESU KONSTRUKCJI → fałszywy CZERWONY.**
`grep 'kind = "([a-z_]+)"'` po `src/server/*.lua` zebrał też pola **telemetrii**
(`Telemetry.emit("game.first_interaction", { kind = "fire" })`), więc strażnik
krzyczał o efekcie `fire` bez konsumenta, którego producent nigdy nie wysyłał.
**Reguła:** zbieraj wartość TYLKO z wywołania właściwego konstruktu —
`text:gmatch('effect%(.-kind = "([a-z_]+)"')` (w Lua `.` łapie też nową linię,
więc działa na wieloliniowych blokach). Rozszerzenie §35: tam kryterium było
„podzbiór kontraktu", tu „konstrukt, nie dowolny literał w pliku".

**(b) Detektor na LITERAŁACH → fałszywy ZIELONY na wartościach DYNAMICZNYCH.**
Ta sama sesja: `Director:bossPower` wysyłał `kind = event`, gdzie `event` to
string **zwracany** przez `BossEncounter.advance` (`return "boss_charge"` /
`"boss_shockwave"`). Literałowego `kind = "..."` tam NIE MA, więc strażnik
pokrycia świecił na zielono — a boss ładował cios 1,5 s i uderzał 18 studami
**bez żadnego znaku na ekranie** (dla dziecka: obrażenia znikąd).

**Reguła (zamyka oba tryby):** przy każdej parze producent→dyspozytor bramkuj
**ZBIÓR ZWRACANY przez producenta**, nie literały w dyspozytorze:

```lua
local kinds = {}
for k in producerSrc:gmatch('return "(boss_[a-z_]+)"') do kinds[#kinds+1] = k end
for _, k in ipairs(kinds) do
  check(k .. " ma konsumenta w kliencie",
    consumerSrc:find('payload.kind == "' .. k .. '"', 1, true) ~= nil)   -- FAIL przy braku
end
```

Dopisuj jawną tabelę WYJĄTKÓW z POWODEM (np. kindy obsługiwane osobną gałęzią) —
ciche pominięcie to defekt, jawny wyjątek to decyzja.

**(c) Emiter pliku MUSI kompilować wynik PRZED zapisem.** Generator wpinający
wpis do pliku Pythona (opis jako długi, generowany literał) złożył błędny literał
→ `SyntaxError` → **cała dostawa padła**: proces wstaje i umiera, a komunikat
wskazywał plik, nie generator. Leczenie: `compile(src, path, "exec")` w
`try/except` PRZED `open(...).write(src)`; przy błędzie przerwij bez zapisu.
Dodatkowo mierz WYNIK („strona renderuje dokładnie 1 wpis X"), nie tylko źródło —
to złapało drugi defekt: opis generowany z CHANGELOG zawierał token
zarezerwowany strony, więc licznik na RENDEROWANEJ stronie dawał 2 zamiast 1.

**(d) Wygenerowany indeks/dokument MUSI mieć strażnika ŚWIEŻOŚCI.** Gdy katalog
elementów (`docs/ELEMENTY.md` + json) jest generowany ze źródła, zestaw musi
asertować: (1) każdy element ma identyfikator, są unikalne i o jednolitym
formacie, (2) **każdy identyfikator ze źródła występuje w indeksie** (inaczej
dokument cicho się starzeje), (3) generator jest idempotentny (`git diff --quiet`
po ponownym przebiegu). Zmierzone: dodanie nowego elementu bez identyfikatora
zapaliło „element bez kodu" — strażnik zadziałał dokładnie po to, żeby dało się
## 39. CZERWONY na NOWYM niezmienniku: najpierw sprawdź NIEZMIENNIK, nie kod (2026-10-13)

**Objaw:** piszesz nową baterię sprawdzeń (mechanika/fizyka/kontrakty między
modułami), pierwszy przebieg pada — i odruchowo „naprawiasz" KOD. Zmierzone:
dwa z rzędu CZERWONE w jednej baterii były **błędem niezmiennika**, nie produktu.

| Niezmiennik (moje założenie) | Dlaczego był ZŁY | Prawdziwy kontrakt |
|---|---|---|
| „najwolniejszy SPRINT bohatera > najszybszy CHÓD bohatera" | porównuje DWIE RÓŻNE role/postacie (tank sprintem idzie tyle, co szybki zwiadowca chodem — i to jest w porządku) | rozrzut chodów nie rozrywa drużyny; każdy sprintem ucieka hordzie |
| „każda broń palna ma zasięg > najdłuższy zasięg potwora" | istniał ŚWIADOMY archetyp krótkiego zasięgu (11 studów) kontra plujka (14) | broń krótka musi przebijać zasięg walki wręcz; dystansowa — plujkę; największy potwór CELOWO przerasta kij |

**Reguła — kolejność reakcji na CZERWONY z WŁASNEGO, nowego niezmiennika:**

1. **Nazwij ROLE obu stron** (pkt 1c: „mierzysz nie tę rolę"). Jeśli porównujesz
   byty pełniące różne funkcje, równość/nierówność NIE jest kontraktem.
2. **Zapytaj, czy kontrakt w ogóle istnieje** — czy nie jest to Twoja opinia o
   designie przebrana za prawo. Kontrakt musi mieć uzasadnienie domenowe
   („da się uciec", „nie ma one-shota"), nie „wydawało mi się sensowne".
3. **Jeśli niezmiennik jest zły — przepisz GO, nie kod**, i zostaw w komentarzu
   ślad: co było założeniem, dlaczego fałszywe, jaki jest prawdziwy kontrakt.
4. **Jeśli kontrakt jest prawdziwy, ale ma wyjątki — zrób je JAWNE z POWODEM**
   (osobna gałąź klasy: „broń krótka", „tank nie jest karany"), nigdy przez ciche
   osłabienie progu (`>= x*0.9`) — to maskowanie, ta sama klasa co allowlista
   pełna fałszywek (§33).

**Dwa antywzorce w SAMYM strażniku, oba zmierzone w tej samej baterii:**

- **Asercja TAUTOLOGICZNA.** `check("klient rysuje X", 'payload.kind == "X"' ~= nil)`
  — porównanie literału do `nil` jest ZAWSZE prawdziwe, więc sprawdzenie
  „przechodzi" niezależnie od stanu repo. Warunek, który da się policzyć w głowie
  bez czytania kodu, jest podejrzany. Porównuj **WYNIK odczytu pliku**:
  `local src = read("src/client/ClientController.lua")` +
  `check(..., src:find('payload.kind == "X"', 1, true) ~= nil)`.
- **FUNKCJA przekazana zamiast jej wyniku** (np. `check("...", (function() … end)(), …)`
  albo funkcja jako warunek) — obiekt ≠ nil, więc zawsze zielono. Pilnuj liczby
  argumentów `check()` i tego, czy warunek jest BOOLEANEM z pomiaru.

**Wartość baterii mimo pomyłek:** po naprawie niezmienników ta sama bateria
złapała realne zależności między systemami (fizyka pościgu, budżet anty-cheatu,
TTK/DPS vs HP potworów, brak one-shotów). Klasa „licz KONTRAKTY MIĘDZY tabelami
konfiguracji, nie tylko istnienie pól" jest warta pisania — ale PIERWSZY przebieg
nowej baterii traktuj jako test JEJ SAMEJ, nie produktu.

o elemencie rozmawiać jednym tokenem (`W12`, `Z11`, `H06-S03`). Pułapka
kolejności: `git diff --quiet` na świeżo zregenerowanym pliku daje FAIL, dopóki
nie zrobisz commita — to artefakt pomiaru, nie rozjazd.


## UZUPEŁNIENIE z renderu SSOT (auto-merge 2026-10-16)
# Verification guard integrity — sprawdzian, który nie może skłamać

# Skorupy narzędzi pomiarowych, które kłamią na własnym formacie (zmierzone 2026-10-15)

Sześć przypadków z JEDNEJ sesji, w których **narzędzie pomiarowe** dało fałszywy werdykt —
nie produkt, nie dane, tylko sam miernik. Wszystkie wyglądały jak wynik. Klasa jest ta sama:
**detektor psuje się na własnym formacie**, a nie na mierzonym obiekcie.

Reguła zbiorcza: gdy werdykt jest NEGATYWNY (FAIL / „brak" / „CRITICAL") ZANIM ogłosisz defekt,
sprawdź, czy **detektor w ogóle umiał zmierzyć** — uruchom go na obiekcie, o którym WIESZ,
że jest dodatni (KONTROLA POZYTYWNA) i na takim, o którym wiesz, że jest ujemny (KONTROLA NEGATYWNA).
Bez obu kontrola nie istnieje (ta sama zasada co „bramka musi mieć dowód negatywny").

## 1. `set -o pipefail` + `grep -q` → ZNALEZIONY string raportowany jako brak
```bash
set -uo pipefail
unzip -p "$APK" classes*.dex | strings | grep -q 'X-Pairing-Token'   # FAŁSZ, gdy string JEST
```
`grep -q` kończy się po pierwszym trafieniu i **zamyka rurę** → producent dostaje SIGPIPE (141) →
przy `pipefail` status CAŁEGO rurociągu != 0 → `if` widzi porażkę. Zmierzone: PASS bezpośrednio,
FAIL w skrypcie — ten sam obiekt.
**Fix:** licz wystąpienia i porównuj liczbę, nie używaj `-q` w rurociągu pod `pipefail`:
```bash
N=$(… | grep -c 'X-Pairing-Token' || true); [ "${N:-0}" -ge 1 ] && ok || no
```

## 2. `grep` po CAŁYM pliku łapie twoje własne komentarze opisujące antywzorzec
Detektor „czy w źródle zostało `dpm list-active-admins`" zapalał się na **komentarzu**, który tę
pułapkę opisywał. Ta sama klasa: test czytający surowy tekst krzyczy o słowie użytym w komentarzu
(zmierzone też w Kotlin: literalne `uses-permission` w komentarzu = FAIL testu).
**Fix:** oceniaj KOD, nie prozę — `CODE="$(grep -vE '^[[:space:]]*#' "$SRC")"` i grepuj po `$CODE`.

## 3. `cargo test -- --nocapture` rozjeżdża format linii werdyktu
Z `--nocapture` stdout testu wchodzi w tę samą linię co `test <nazwa> ... ok`, więc wzorzec
`... ok` przestaje pasować → **fałszywy FAIL dla testu, który przeszedł** (widać było jego własny
`[DOWÓD …]`, więc test WYKONAŁ SIĘ w całości).
**Fix:** nie parsuj linii werdyktu z `--nocapture`; albo bez flagi, albo czytaj
`test result: ok. N passed; 0 failed`.

## 4. Dobór katalogu/pliku dowodowego „najnowszy" trafia w inny przebieg
`EV="$(ls -dt evidence/*/ | head -1)"` wzięło katalog z przebiegu uruchomionego dla JEDNEGO
urządzenia → brak podkatalogu drugiego → kontrola pozytywna „nie wykrył admina" (fałszywy FAIL).
**Fix:** nie bierz „najnowszego" — bierz pierwszy, który **zawiera wymagany artefakt**:
```bash
for d in $(ls -dt evidence/*/); do [ -f "$d/$CEL/plik.txt" ] && { EV="$d"; break; }; done
```

## 5. `ssh` w pętli `while read` pożera STDIN → pętla kończy się po 1. iteracji
```bash
while read -r T; do ssh host "curl … $T …"; done < plik      # wykona się RAZ
```
`ssh` dziedziczy stdin pętli i zjada resztę pliku. Objaw: „tylko pierwszy element przetworzony",
a wynik wygląda na sukces.
**Fix:** `ssh -n` (albo `< /dev/null`) dla każdego wywołania w pętli.

## 6. Licznik zbyt szeroki → fałszywy alarm; licznik zbyt wąski → fałszywa zieleń
`pm list packages -u` (bez `-3`) zwraca setki systemowych wpisów „kiedykolwiek" (311/334 na
SPRAWNYM telefonie) i zapalał ostrzeżenie o ukrytym oprogramowaniu. Zawężenie do `-3 -u` (31/26)
dało sygnał. Lustrzany przypadek: polecenie, którego na tym buildzie **nie ma** (`dpm
list-active-admins` → `Unknown command`), schodziło do gałęzi „brak" — czyli fałszywa zieleń.
**Fix:** pojedynczy próg dobieraj do rozkładu (zmierz oba: zdrowy i podejrzany), a na błąd
NARZĘDZIA (`Unknown command`, `SecurityException`, rc≠0) odpowiadaj `SKIP`, nigdy PASS.

## Wniosek do raportu
Każde z tych zdarzeń zgłoś jako **defekt miernika**, nie produktu — i napraw miernik PRZED
następnym werdyktem. Kolejność „napraw kod, bo test czerwony" bez sprawdzenia detektora to
najdroższy błąd tej klasy.

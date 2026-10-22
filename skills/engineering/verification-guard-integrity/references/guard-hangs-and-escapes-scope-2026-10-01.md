# Strażnik, który WISI · auto-remediacja, która WYCHODZI ZA ZAKRES · strażnik ZA SZEROKI

Trzy objawy, jedna klasa: **strażnik/automat działa poza granicą, którą sam sobie
wyznaczył** — za długo, za szeroko, za głęboko (przez dowiązanie). Lek jest ten sam:
nazwij granicę (czas, zbiór, zakres), egzekwuj ją w kodzie i UDOWODNIJ pomiarem po
przebiegu, że trzyma. Wszystko poniżej zmierzone 2026-10-01 na <workspace>.

---

## A. BRAMKA, KTÓRA WISI — gorsza niż czerwona

**Objaw:** `verify reconcile` stał na module `i18n` — 11 modułów PASS / 9 FAIL
i **brak EXIT po godzinie**. `timeout 90` na samym module → `rc=124` (timeout).
Nie dało się odróżnić „wolno liczy" od „nigdy nie skończy".

**Przyczyna (w `tools/verify/i18n/i18n.sh`, INT-03):** dla KAŻDEGO pliku pętla
`while IFS= read -r line; do … printf '%s' "$line" | grep -qE '…' ; done`
— czyli **podproces na KAŻDĄ LINIĘ** każdego pliku źródłowego → dziesiątki tysięcy
podpowłok. Złożoność O(linie) fork-ów zamiast O(pliki).

**Dlaczego gorsza od czerwonej:** czerwona mówi „coś jest źle". Wisząca nie mówi
NIC — nie wiadomo, czy przebieg się skończył, więc nie da się jej odróżnić od
wolnego liczenia i cała certyfikacja stoi w nieskończoność.

**Fix:** JEDEN przebieg `grep` na PLIK, liczenie linii przez `wc -l`:
```bash
matches=$(grep -nE '"[^"]*[A-Za-z][^"]* [^"]*"' "$f" 2>/dev/null) || true
[ -n "$matches" ] || continue
n=$(printf '%s\n' "$matches" | wc -l)
```
NIE używaj `grep -q` w potoku — pod `pipefail` łapie SIGPIPE i daje fałszywe rc.
Do liczenia zawsze `grep -c` / `wc -l`.

**Pomiar po naprawie:** `rc=0`, **43,6 s**, `CERTIFICATION: PASS`.

**Reguły:**
1. Każdą bramkę uruchamiaj z własnym `timeout`; przekroczenie = FAIL, nie „trwa".
2. W pętli po plikach **nigdy** nie odpalaj podprocesu per-linia — jeden per plik.
3. Moduł, który przekracza ~10× medianę pozostałych, to defekt wydajności, nie
   „duży zakres" — zmierz czasy per moduł, zanim uznasz go za wolny z natury.
4. Bramka zagnieżdżona (moduł w module) musi mieć limit także na poziomie
   nadrzędnym — inaczej jeden wiszący moduł kładzie cały przebieg.

---

## B. AUTO-REMEDIACJA, KTÓRA WYCHODZI POZA ZAKRES (symlink = wejście na system)

**Zmierzone:** w repo leży dowiązanie do binarki systemowej:
```
<workspace>/.venv-ytdlp/bin/python3  ->  /usr/bin/python3
```
`chmod`/`chown` **NA SYMLINKU działa na CELU**. Dwa automaty (cron) —
`scripts/audit-fileperm.py --apply` (chmod+chown) oraz
`scripts/enforce-ownership-canon.sh` (`find … -print0 | xargs chown`) — „naprawiały
uprawnienia w repo", a przestawiły SYSTEMOWĄ binarkę:
`/usr/bin/python3.12` z `root:root 755` na **`aigon:aigon 644`**.

**Skutek:** `python3` przestał się uruchamiać dla CAŁEGO hosta (plik bez bitu `+x`
→ `execve` = EACCES, **nawet dla roota**) → masowe `RC=126` w cronach i padające
hooki pre-push. Objaw mylący: wygląda jak awaria setek skryptów.

**Detekcja:**
```bash
find /usr/bin -maxdepth 1 -type f ! -perm -u+x      # binarki bez +x
stat -c '%a %U:%G %z' /usr/bin/python3.12           # tryb, właściciel, ctime
find <workspace> -maxdepth 3 -type l                  # dowiązania wychodzące z repo
```
`tools/gates/domains/system-bin-perms-guard.sh` wykrywa tę klasę — ale **nie był
w cronie**, więc nie złapał. Strażnik istnieje ≠ strażnik pilnuje (guard-on-guard).

**Fix klasy (nie objawu):**
1. Python: `if os.path.islink(full): continue` (także dla katalogów w `os.walk`).
2. Shell: `find <root> … ! -type l …` — wykluczenie po stronie `find`, bo `find`
   testuje własność DOWIĄZANIA (`lstat`), a `chown` już za nim idzie.
3. Każdy automat zmieniający uprawnienia działa TYLKO na `-type f` i ma jawną
   granicę zakresu.

**Dowód naprawy (liczbowy, nie deklaracja):** remediacja zeszła z
`naprawiono 6357 plików` na `naprawiono 4`; `ctime` binarki systemowej **nie
zmieniło się** po przebiegu (`PRZED 755 root:root` == `PO 755 root:root`).

**Reguła nadrzędna:** przy każdej automatyzacji zmieniającej stan (`chmod`,
`chown`, `rm`, `mv`) — wypisz, JAKI zbiór może dotknąć, i udowodnij pomiarem
atrybutu PRZED/PO, że nie wychodzi poza niego. „Naprawa" bez pomiaru zakresu to
zgadywanie — a ta konkretna zabiła hostowi interpreter.

---

## C. STRAŻNIK ZA SZEROKI BLOKUJE WSZYSTKIM (FAIL vs WARN)

**Zmierzone 4× w jednej sesji:** `tools/gates/scripts-wired-check.sh` oraz
`repo-completeness.sh` blokowały pre-commit **WSZYSTKIM** z powodu plików, które
NIE były częścią kontraktu repo:
- **nieśledzone** (`prompt_index.py`, `hermes-mesh-dashboard.sh`) — praca w toku
  RÓWNOLEGŁEJ sesji,
- **tylko zestagowane** (`git add` bez commita — `skill-description-trim.py`).

**Dlaczego to defekt bramki, nie kodu:** plik, który nie jest częścią repo, nie ma
żadnej deklaracji, więc nie może jej łamać. Bramka karała wszystkich za cudzą pracę
w locie.

**Fix (rozdział kontraktu od pracy w toku):**
- „zadeklarowany w repo, ale niewpięty" → **FAIL** (realny defekt: *napisane = podpięte*),
- „poza HEAD" (untracked / staged-only) → **WARN z NAZWĄ pliku**.

**Pułapka przy implementacji (zmierzona):**
- podstawą jest **`git ls-tree -r HEAD --name-only`**, NIE `git ls-files`
  (`ls-files` czyta **INDEKS**, więc samo `git add` bez commita wygląda jak
  „zadeklarowane w repo" i daje FAIL),
- w bloku Pythona zmienna to `root` (małe litery) — użycie `ROOT` daje `NameError`,
  które zostaje połknięte przez `except Exception` i **cicho wyłącza całą
  klasyfikację**. Wniosek: wynik klasyfikacji trzeba WIDZIEĆ (loguj, ile wpisów
  trafiło do której kategorii), nie tylko status.

**Zabezpieczenie przeciw fałszywej zieleni:** `if tracked:` — gdy git nie odpowie
(brak repo / błąd / pusty wynik), **NIE przeklasyfikowuj niczego**. Inaczej pusty
zbiór zrobiłby ze WSZYSTKICH sierot „WIP" i bramka przepuszczałaby martwy kod.

**Reguła:** strażnik, który nie pozwala zapisać pracy z powodu cudzej pracy w toku,
sam staje się przeszkodą. Bramka ma (1) nazywać pliki, (2) rozdzielać „naruszenie
kontraktu" od „praca w toku", (3) nie dać się wyłączyć cichym wyjątkiem.

Odmiana tej samej klasy (odwrotna strona): gdy **usunięcie** blokady wymaga decyzji
o cudzym pliku, wpis do allowlisty musi być **jawny i uzasadniony** (np.
`config/canonical/scripts-orphans.json`, `tools/gates/repo-completeness-allowlist.txt`)
— a nie `--no-verify`. Obchodzenie bramki jest zakazane kanonem; wpis z powodem
zostawia ślad i nie blokuje innych.

---

## D. Wspólny wzorzec rozpoznawczy

| Objaw | Pytanie diagnostyczne | Granica, której brakowało |
|---|---|---|
| „przebieg trwa i trwa" | ile podprocesów na jednostkę danych? | CZAS (`timeout` + O() per plik, nie per linia) |
| „narzędzie naprawiło coś poza repo" | czy dowiązanie wyprowadza poza zakres? | ZAKRES (skip `-type l` / `islink`) |
| „bramka blokuje wszystkich" | czy plik jest częścią kontraktu (`ls-tree HEAD`)? | ZBIÓR (FAIL kontrakt vs WARN praca-w-toku) |

Wspólny test końcowy: **po przebiegu zmierz, czy granica trzyma** — czas (rc +
wallclock), zakres (atrybut celu PRZED/PO), zbiór (nazwy w każdej kategorii).

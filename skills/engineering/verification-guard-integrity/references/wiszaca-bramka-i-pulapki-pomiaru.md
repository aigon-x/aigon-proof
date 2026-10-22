# Bramka, która WISI — i trzy dalsze pułapki tożsamości pomiaru (2026-10-01)

Uzupełnienie do klasy „strażnik, który nie może skłamać". Wszystkie przypadki
ZMierzone na żywym systemie w jednej sesji.

---

## 1. Bramka WISZĄCA jest groźniejsza od czerwonej

**Objaw:** cały `verify reconcile` (orkiestrator wielu modułów) nie kończył się
NIGDY — po godzinie stał na module `i18n`, bez `EXIT` w logu. Nie było werdyktu,
więc nie dało się odróżnić „przebieg trwa" od „przebieg nie żyje".

**Przyczyna (zmierzona):** moduł robił `grep` NA KAŻDĄ LINIĘ każdego pliku źródłowego:

```bash
# ANTY-WZORZEC — pętla w pętli, podpowłoka NA LINIĘ
while IFS= read -r f; do
  while IFS= read -r line; do
    if printf '%s' "$line" | grep -qE '...'; then   # ← fork na KAŻDĄ linię
      HITS=$((HITS+1))
    fi
  done < <(grep -nE '...' "$f" 2>/dev/null)
done < <(repo_files)
```

Na repo z tysiącami plików to dziesiątki tysięcy `fork()` → praktycznie nieskończoność.

**Naprawa:** JEDEN przebieg `grep` na plik + liczenie linii `wc -l`:

```bash
matches=$(grep -nE '...' "$f" 2>/dev/null) || true
[ -n "$matches" ] || continue
n=$(printf '%s\n' "$matches" | wc -l)
HITS=$((HITS + n))
```
Zmierzone: **timeout (>90 s, bez końca) → 43,6 s, `CERTIFICATION: PASS`**.

**Reguła:** każda bramka MUSI mieć twardy limit czasu na moduł. Brak timeoutu =
brak werdyktu = bramka bezużyteczna. `timeout 150 bash <gate>` jako standard
diagnostyczny; jeśli rc=124 — to defekt bramki, nie „wolna maszyna".

---

## 2. Bramka wciąga ŚMIETNIK, bo lista plików ma fallback na dysk

Ten sam moduł brał listę plików z funkcji mającej **fallback na listing z dysku**
(gdy `git ls-files` jest pusty). Fallback wciągnął katalog `.dustbin-*` z usuniętymi
skillami → **109 153 „trafienia"** i próbka z kosza.

**Naprawa:** jawny filtr katalogów-śmietników/artefaktów w samej bramce
(`.dustbin*`, `_archive/`, `.archive/`, `node_modules/`, `target/`).

**Reguła:** jeśli bramka opisuje „jakość kodu", a skanuje pliki spoza kodu
produkcyjnego — liczby są bez znaczenia, a werdykt mylący. Zawsze pytaj:
*co dokładnie weszło do zbioru wejściowego i czym to sprawdzić*.

---

## 3. Hash hosta vs hash z kontenera: SYMLINK = trwały fałszywy rozjazd

**Objaw:** bramka `config-consistency` raportowała DRIFT bind-mountowanego pliku
`/etc/localtime` w dwóch kontenerach — przy ZEROWYM realnym dryfie.

**Dowód rozstrzygający (rób to ZAWSZE, zanim „naprawisz"):**
```bash
sha256sum "$SRC"                                    # host, idzie ZA dowiązaniem
docker cp "$CID:$DST" /tmp/x && sha256sum /tmp/x    # docker cp kopiuje SAM LINK
docker exec "$CID" sha256sum "$DST"                 # ← MIARA WŁAŚCIWA (wnętrze kontenera)
```
Wynik: `4e22c33d…` (host = treść Europe/Warsaw) vs `8b858467…` (docker cp, link
rozwiązany w przestrzeni hosta inspekcjonującego → Etc/UTC), a `docker exec`
zwróciło **dokładnie ten sam hash co host**. Kontener miał poprawną strefę.

**Naprawa:** w bramce, PRZED porównaniem:
```bash
if [ -L "$src" ]; then
  SKIPPED=$((SKIPPED+1))
  SKIPS+=("$cname:$dst (host: dowiązanie symboliczne — docker cp nie odwzorowuje go wiernie; pominieto)")
  continue
fi
```
**jawny SKIP, nie ciche PASS.**

**Reguła klasy:** zanim zgłosisz defekt, sprawdź, czy DWIE MIERZONE WARTOŚCI opisują
tę samą rzecz. „Host za linkiem" i „link rozwiązany gdzie indziej" to dwie różne role —
ich porównanie jest fałszywe z definicji. Restart usługi NIC by nie naprawił:
to BRAMKA była zepsuta.

---

## 4. Bramka, która nie podaje NAZW — to defekt bramki

Wzorzec zły: `repo-completeness: FAIL — 2 deklaracji bez pliku w indeksie gita`
(bez nazw — nie da się zaadresować bez ponownego uruchomienia).
Wzorzec dobry: `scripts-wired-check: FAIL — sierota: <nazwa pliku> [klasa]`.

**Reguła (rozkaz Suwerena):** werdykt FAIL bez listy naruszających ścieżek jest
bezużyteczny. Pisząc bramkę — **zawsze wypisz konkretne ścieżki/identyfikatory**
plus jednoznaczną instrukcję naprawy (`git add <ścieżka>` albo „dopisz do allowlisty
z uzasadnieniem").

---

## 5. Allowlista zamiast obchodzenia bramki

Gdy commit blokuje sierota **cudzego** pliku (np. skrypt równoległej sesji
zadeklarowany w cronie, ale nie w indeksie gita):

- ❌ `git commit --no-verify` — kanon zabrania obchodzenia bramek.
- ❌ `git add` cudzego pliku w trakcie jego edycji — wejście w cudzą pracę w locie.
- ✅ wpis do allowlisty bramki **z uzasadnieniem, które ODKRYWA stan** (mtime, fakt
  „edytowany teraz przez równoległą sesję", „decyzja należy do autora") — nie ukrywa
  problemu, a odblokowuje commity wszystkim.

Wzorzec wpisu:
```
<ścieżka>   # ZADEKLAROWANY w cronie i ŻYWY na dysku, ale edytowany TERAZ przez
            # równoległą sesję (mtime 02:09). Nie wciągam cudzej pracy w locie.
            # DECYZJA O COMMIT NALEŻY DO AUTORA. Wpis jawny, nie ukrywa stanu.
```

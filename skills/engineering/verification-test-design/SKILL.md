---

name: verification-test-design
description: "Projektowanie testów weryfikujących WŁASNĄ zmianę (skrypty, hamulce, bramki, wrappery) tak, by testy same nie kłamały i realnie łapały bugi. Zawiera cztery zmierzone klasy fałszywych wyników (test dosłowny, test na zmiennym stanie, pgrep łapiący własne polecenie, brak testu negatywnego) oraz wzorzec testu deterministycznego przez env. Użyj ZAWSZE gdy kończysz zmianę w skrypcie/bramce/wrapperze i musisz udowodnić że działa — a także gdy test FAIL-uje i nie wiesz, czy winien jest kod czy test."
see_also: ['heavy-io-guard-and-cpu-isolation']
---


# Projektowanie testów weryfikujących własną zmianę

## Po co ten skill
Zmierzone w jednej sesji: **cztery fałszywe wyniki** i **dwa prawdziwe bugi** znalezione
wyłącznie dlatego, że testy były napisane dobrze. Test, który kłamie w obie strony
(fałszywy PASS i fałszywy FAIL) jest gorszy niż brak testu — daje złudzenie dowodu.

**Reguła:** gdy test FAIL-uje, ZAWSZE najpierw rozstrzygnij: **winien kod czy test?**
W tej sesji 3 z 4 FAIL-i były winą testu. Nie „naprawiaj" kodu pod zły test.

## Cztery klasy fałszywych wyników (wszystkie zmierzone)

### 1. Test sprawdzający LITERAŁ, nie INTENCJĘ → fałszywy FAIL
```
BYŁO:  grep -q 'timeout 300 sqlite3' "$SKRYPT"     # → FAIL "brak timeoutu"
FAKT:  kod miał timeout przez zmienną: timeout "$SQL_TIMEOUT" sqlite3
       → czyli MOCNIEJ (konfigurowalny), a test tego nie widział
LEKCJA: grepuj po intencji (obecność timeoutu + zmiennej), nie po dosłownym stringu
```

### 2. Test mierzący ZMIENNY stan hosta → fałszywy FAIL
```
BYŁO:  uruchom guard, sprawdź "env override działa"  na żywym loadzie
       → raz przechodził, raz nie — zależnie od chwilowego obciążenia
LEKCJA: wymuś stan przez env, żeby wynik był deterministyczny:
        AIGON_IO_GUARD_LOAD_MAX=99999999 <guard> --check   # MUSI przepuścić
        AIGON_IO_GUARD_LOAD_MAX=0        <guard> --check   # MUSI zablokować
```

### 3. `pgrep -f` / `pkill -f` łapie WŁASNE polecenie → fałszywy PASS
```
BYŁO:  pgrep -f "sleep 337"  → "★ ZYJE"      # potomek rzekomo nie ubity
FAKT:  pgrep dopasował CAŁĄ linię polecenia, która zawierała tekst "sleep 337"
       → to było MOJE polecenie, nie potomek
SKUTEK: o mało nie "naprawiłem" działającego kodu pod fałszywy alarm
LEKCJA: weryfikuj po cmd/PGID, nie po -f:
        ps -eo pid,etimes,comm | awk '$3=="sleep"' | while read p e c; do
          ps -o cmd= -p $p | grep -q "sleep 337" && echo "ZYJE"
        done
```
**Ta sama pułapka jest destrukcyjna w `pkill`:** `pkill -f "hook-runner.sh X"` zabił
powłokę nadrzędną (exit -15). Nigdy `pkill -f` ze stringiem, który sam wpisałeś.

### 4. Brak testu NEGATYWNEGO → nie wiesz, czy hamulec hamuje
Hamulec/bramka bez testu negatywnego to obietnica, nie mechanizm:
```bash
# pozytywny: ma przepuścić
<guard> → rc=0, "WOLNO"
# negatywny (KRYTYCZNY): ma ZABLOKOWAĆ
<guard> → rc=1, "NIE WOLNO"
```
Test wyłącznie pozytywny przechodzi również wtedy, gdy hamulec **nie podłączony**.

## Dwa prawdziwe bugi złapane TYLKO dzięki tym testom
1. **Odwrócony warunek progu** — `awk '$1 > 60 && $1 <= max'` łapał procesy krótsze
   niż próg, więc hamulec nie działał w żadnym realnym przypadku. Test z progiem `0`
   („musi zablokować") to wykrył.
2. **`timeout cmd` nie ubija potomków** — rc=124 OK, ale `sleep 300` żył dalej.
   Test sprawdzający **los potomka**, nie tylko kod wyjścia, to wykrył.

**Wniosek: testuj SKUTEK (czy potomek umarł, czy próg zadziałał), nie tylko exit code.**

## Szablon testu weryfikującego zmianę
```bash
#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ok(){ echo "  PASS: $*"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

# A. SKLADNIA — najtańszy test, rób pierwszy
bash -n "$SKRYPT" && ok "bash -n" || bad "bash -n"

# B. MECHANIZM JEST W KODZIE (intencja, nie literał)
grep -q '<zmienna-env>' "$SKRYPT" && ok "env nadpisywalny" || bad "brak env"

# C. KONTRAKT — deterministycznie, przez env
OUT=$(<prog1> <guard> <args>); [ $? -eq 0 ] && ok "przepuszcza" || bad "nie przepuszcza"
OUT=$(<prog0> <guard> <args>); [ $? -eq 1 ] && ok "blokuje"   || bad "nie blokuje"

# D. SKUTEK — nie tylko exit code
<uruchom> <wiszące> & pid=$!; sleep 2
ps -o cmd= -p $pid >/dev/null 2>&1 && bad "POTOMEK ZYJE" || ok "potomek ubity"

echo "=== WYNIK: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] || exit 1
```

## Kolejność i higiena
1. **Składnia → mechanizm → kontrakt → skutek.** Od najtańszego.
2. **Sprawdź warunek wstępny** (`--status` guarda) — nie odpalaj ciężkiego testu na
   zakorkowanym hoscie (patrz `heavy-io-guard-and-cpu-isolation`).
3. **Uruchom istniejące harnessy repo**, nie tylko własny test:
   `npm run test` (jeśli istnieje), `pytest scripts/test_*.py`, bramki hooków.
   Własny test nie zastępuje harnessu — uzupełnia go.
4. **Sprzątaj:** usuń skrypt weryfikacyjny (`rm -f /tmp/verify-*.sh`) i katalogi testowe,
   chyba że user chce je zachować jako `scripts/` w skillu.
5. **Nazwij wprost, co zweryfikowano, a co nie.** „Testy ad-hoc PASS=22/0" ≠
   „suite green". Rozróżniaj: harness repo vs własny test vs brak pokrycia.

## Uczciwość raportu
- Nie ogłaszaj sukcesu na podstawie exit code (`cargo Finished` ≠ binarka odświeżona).
- Gdy test nie mógł się wykonać (blokada uprawnień, brak dostępu), napisz to wprost —
  to NIE jest PASS.
- Gdy jeden test FAIL-uje, zbadaj czy to kod czy test, ZANIM cokolwiek zmienisz.
- Zmiana kontraktu (np. `rc=124` → `rc=143`) = udokumentuj ją w kodzie i w raporcie.

## Powiązane
- `heavy-io-guard-and-cpu-isolation` — obiekt testowania w tej sesji
- `false-green-elimination` — szersza doktryna fałszywych sukcesów
- `deploy-verification-not-rsync-exit` — weryfikacja wdrożenia odczytem sum

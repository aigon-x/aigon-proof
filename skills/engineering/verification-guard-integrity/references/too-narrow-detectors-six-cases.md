# Detektor za wąski — sześć przypadków, jedna sesja

Zmierzone 2026-10-01 (`<workspace>`). **Wszystkie sześć dały fałszywy wynik na
sprawnym systemie.** Żaden nie był awarią systemu — każdy był wadą MOJEJ sondy.

Reguła nadrzędna: **zanim ogłosisz defekt, sprawdź, czy twój detektor patrzy
na właściwą rzecz.** Fałszywy czerwony kosztuje tyle samo co fałszywy zielony —
blokuje uzasadnioną naprawę i podważa raport.

---

## 1. `grep -q` na nazwie TRAFIŁ W KOMENTARZ

**Objaw:** warunek `grep -qE "^Environment=OLLAMA_NUM_PARALLEL="` pomijał plik,
bo wcześniej trafił na **komentarz** zawierający tę samą frazę
(`# OLLAMA_NUM_PARALLEL -> liczba watkow`). Efekt: zmienna NIE została dopisana,
a moja weryfikacja meldowała „już ustawione".

**Lekarstwo:** zakotwicz wzorzec na **kształcie danych**, nie na nazwie:
`grep -qE '^Environment=OLLAMA_NUM_PARALLEL='` (z `^` i znakiem `=`).
Po każdej zmianie potwierdź **odczytem realnego stanu** (env procesu:
`tr '\0' '\n' < /proc/$PID/environ | grep ...`), nie obecnością pliku.

---

## 2. `docker exec ... strings` = BRAK BINARKI, błąd na STDOUT

**Objaw:** szukałem FEC/Reed-Solomon w binarce przez
`docker exec <c> strings /usr/local/bin/bin | grep -c parity` → **0 trafień** →
ogłosiłem „BRAK FEC w produkcyjnym routerze". **Nieprawda.**

W distroless/slim **`strings` nie istnieje**. Błąd `sh: strings: not found`
poszedł **na STDOUT**, a ja liczyłem trafienia w tym komunikacie.

**Lekarstwo:** wyciągnij binarkę na host i zmierz tam, potem **sprawdź, że to
ELF**:

```bash
docker cp <kontener>:/usr/local/bin/<bin> /tmp/bin
head -c4 /tmp/bin | xxd | grep -q '7f45 4c46' || echo "TO NIE ELF"
strings /tmp/bin | grep -cE 'parity|reed_solomon|erasure'
```

Dodatkowy dowód tożsamości: `md5sum` binarki z kontenera **vs** z `target/release`.
W sesji hashe były IDENTYCZNE (`103f81d2…`) — czyli binarka w kontenerze była
ta sama co na dysku, a „brak FEC" był czystym artefaktem sondy.

**Reguła ogólna:** `docker exec` na brakującym narzędziu pisze błąd na STDOUT —
`if out:` widzi „nieistniejący interpreter". Sprawdzaj **kod wyjścia**.

---

## 3. `pgrep -fc` LICZYŁO WŁASNE SONDY

**Objaw:** `pgrep -fc llama-server` pokazało 4 procesy na węźle → ogłosiłem
over-subscription. Realnie były **2** — pozostałe dwa to moje własne `grep`/`ssh`,
które zawierały ten string w linii poleceń.

**Lekarstwo:** licz po **nazwie procesu**, nie po treści komendy:
`pgrep -x llama-server` (dokładne dopasowanie nazwy) albo przez
`ps -eo comm=` + filtr. Po ogłoszeniu liczby **zweryfikuj ją drugim źródłem**
(np. suma wątków z `/proc/<pid>/status`).

---

## 4. `ControlMode` to NIE opcja ssh

**Objaw:** sonda SSH z `-o ControlMode=no` kończyła się
`Bad configuration option: controlmode` → `rc != 0` → **6 z 7 węzłów
raportowanych jako „brak pomiaru"**. Węzły żyły i odpowiadały.

**Lekarstwo:** poprawna nazwa to **`ControlMaster`**. Gdy sonda zbiorcza pokazuje
„większość węzłów martwa", **przetestuj sondę na JEDNYM węźle ręcznie** i
przeczytaj pełny stderr — zanim uznasz mesh za padnięty.

**Reguła:** „brak pomiaru" i „obiekt nie żyje" to DWIE RÓŻNE rzeczy i wymagają
różnych reakcji. Raport musi je rozróżniać.

---

## 5. CPUQuota: systemd zwraca SEKUNDY, nie mikrosekundy

**Objaw:** parser robił `CPUQuotaPerSecUSec / 10000` → **0%** → raport
„CPUQuota BRAK (limit nieustawiony)" na węźle, gdzie limit **działał** (960%).

Realny format: `systemctl show ollama -p CPUQuotaPerSecUSec --value` zwraca
**`9.600000s`** — liczbę sekund z sufiksem, mimo nazwy `…USec`.

**Lekarstwo:** obetnij sufiks i przelicz:

```bash
RAW=$(systemctl show <svc> -p CPUQuotaPerSecUSec --value)
case "$RAW" in
  infinity|""|0) PCT=0 ;;
  *s) PCT=$(echo "$RAW" | sed 's/s$//' | awk '{printf "%d", $1*100}') ;;
  *)  PCT=$(( ${RAW%.*} / 10000 )) ;;
esac
```

**Reguła:** gdy pole nazywa się `…USec`, a wygląda jak sekundy — **wydrukuj surową
wartość i przeczytaj ją**, zanim napiszesz parser.

---

## 6. Ta sama wartość liczona w DWÓCH miejscach → pętla samonaprawy

**Objaw:** governor USTAWIAŁ `CPUQuota = cores*60` (prod: 840%), potem MIERZYŁ
i porównywał z `round(cores*0.6)*100` (800%) → raportował **własną naprawę jako
rozjazd**. Pętla restartów donikąd, każdy przebieg „naprawiał" to, co sam przed
chwilą ustawił.

**Lekarstwo:** **jedna funkcja** licząca wartość docelową, wołana i przy naprawie,
i przy ocenie:

```python
def want_cpu_quota(cores, pct_of_cores):
    return int(round(cores * pct_of_cores / 100.0)) * 100
```

**Reguła:** jeżeli mechanizm ma naprawiać i weryfikować to samo — **oba muszą
wołać ten sam kod**. Dwie implementacje tej samej reguły ZAWSZE się rozjadą
(klasa „zduplikowana definicja prawdy").

---

## Wspólny mianownik wszystkich sześciu

Każdy przypadek spełnia ten sam wzorzec: **detektor mierzył tańszą rzecz niż
zamierzoną.**
- obecność frazy zamiast wartości zmiennej (§1)
- brak narzędzia zamiast zawartości pliku (§2)
- treść komendy zamiast nazwy procesu (§3)
- zła nazwa flagi zamiast łączności (§4)
- jednostka zamiast liczby (§5)
- druga implementacja zamiast wspólnej (§6)

**Test przed ogłoszeniem każdego defektu:**
1. Czy mój detektor pyta o **dokładnie** to, co chcę wiedzieć?
2. Czy wynik jest **potwierdzony drugim, niezależnym źródłem**?
3. Czy „brak/zły" wynik odróżnia **brak obiektu** od **awarii sondy**?

Jeżeli na któreś pytanie nie ma odpowiedzi — nie ogłaszaj, popraw sondę.

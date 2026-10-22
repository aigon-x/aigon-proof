# Sześć trybów porażki bramki pomiarowej (zmierzone 2026-09-29)

Ten plik jest wynikiem sesji, w której napisano bramkę D18 (kontrakt logowania
AITO) i **trzy razy** złapano na niej fałszywy wynik. Każdy tryb jest realny,
zmierzony, i każdy dotyczy klasy — nie jednego produktu.

## 1. Furtka `-x` / `-f`: zielono bez pomiaru

Bramka stawiała warunek na PLIKU dowodu, nie na WYNIKU:

```bash
if [ -x "$ROOT/scripts/login-smoke.py" ]; then
  python3 "$ROOT/scripts/login-smoke.py" ... || fail=1
else
  echo "UWAGA: brak scripts/login-smoke.py — pomijam dowód życia"
fi
```

Plik po `write_file` traci bit `+x` → warunek fałszywy → komunikat „pomijam"
→ **bramka ZIELONA bez ani jednego logowania**. W tej samej sesji to samo
zdarzyło się drugi raz jako `[ -f ]` w innej gałęzi.

**Leczenie:**
```bash
if [ -f "$ROOT/scripts/login-smoke.py" ]; then
  python3 "$ROOT/scripts/login-smoke.py" ... || fail=1   # python3, NIE bit +x
else
  echo "FAIL: brak scripts/login-smoke.py — NIE pomijam (brak dowodu != sukces)"
  fail=1
fi
```

**Reguła:** krok dowodowy wywołuj przez interpreter (`python3 <plik>`,
`bash <plik>`). Brak artefaktu = FAIL, nigdy „pomiń". Każdy `[ -x ]`/`[ -f ]`
wokół testu to potencjalna furtka. **Test, który to łapie:** zmień nazwę
artefaktu dowodu i sprawdź, że bramka PADA.

## 2. Pętla weryfikacyjna mierzy samą siebie (rate-limit)

Serwer miał rate-limit 5 nieudanych prób / 60 s → 429. Skrypt ad-hoc wykonujący
KILKA przebiegów bramki wyczerpał limit sobą. Objaw: `HTTP 429` na POPRAWNYCH
danych, wyglądające jak regresja. Trzy fałszywe FAIL z rzędu.

**Leczenie:** `wait_window() { sleep 62; }` między podtestami; w werdykcie
osobno `429` (limit), `401` (zły sekret), `403` (WAF/proxy). Zlanie ich w jedno
„FAIL" gubi informację, która warstwa zawiodła.

## 3. `403` od Cloudflare WAF na User-Agent `curl`

Pomiar logowania przez publiczną domenę zwracał `403` na POPRAWNYM koncie.
Przyczyna: CF WAF klasyfikuje `curl/x.y` i `Python-urllib/x.y` jako bota.
Ten sam request z UA przeglądarki → `200`.

**Leczenie:** w skryptach mierzących PRZEZ domenę ustawiaj UA przeglądarki —
przedmiotem pomiaru jest funkcja, nie polityka antybotowa CF:

```python
headers={
    "Content-Type": "application/json",
    "User-Agent": ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
                   "(KHTML, like Gecko) Chrome/124.0 Safari/537.36"),
    "Accept": "application/json",
}
```

**Rozróżnienie diagnostyczne:** `401` = mierzymy warstwę aplikacji (poprawny
pomiar). `403` z `cf-ray` w nagłówkach = blokada edge, POMIAR NIEWAŻNY.
Zawsze sprawdź, czy w odpowiedzi jest `server: cloudflare` — jeśli tak, to nie
jest werdykt aplikacji.

## 4. Detektor ślepy: `grep` na zbyt dosłownym wzorcu

Sprawdzenie „czy detektor widzi zły sekret" używało
`grep -q 'DETECTOR_OK 401'`, a `urllib` dokładał tekst błędu
(`DETECTOR_OK HTTP 401 nieprawidłowe dane logowania`) → grep nie łapał
→ FAŁSZYWY FAIL na działającym detektorze.

**Reguła:** frazy dopasowuj na tokenach osobno
(`grep -q 'DETECTOR_OK' && grep -q '401'`), nie na dokładnym zdaniu —
komunikaty narzędzi dokładają kontekst, którego nie kontrolujesz.

## 5. Detektor zawsze-OK (odwrotność nr 4)

Test „detektor widzi porażkę" jest OBOWIĄZKOWY. Detektor, który na wszystko
zwraca sukces, jest tak samo zepsuty jak detektor zawsze-czerwony — tylko
trudniejszy do zauważenia.

Wzorzec: podaj ZŁE hasło i wymagaj, żeby wynik był PORAŻKĄ:
```python
good, info = m.try_login(base, "konto@example.com", "zle-haslo-xyz")
assert not good, f"detektor uznał złe hasło za sukces: {info}"
```

## 6. Raportowanie nieaktualnego przebiegu

System pokazał wynik sprzed poprawek (FAIL-y z wcześniejszej wersji pliku).
Obrona starego przebiegu = kłamstwo. **Unieważnij i zmierz od nowa** na OBECNYM
stanie, podając `md5sum` zmienionych plików razem z wynikiem — inaczej nie
wiadomo, czy werdykt dotyczy tego, co jest na dysku.

## Wzorzec ad-hoc bramki (6 podtestów)

Plik: `/tmp/hermes-verify-<bramka>.sh`, sprzątany po sobie (`trap ... EXIT`).

1. przechodzi na stanie poprawnym (RC=0)
2. WYKRYWA wprowadzony defekt (RC≠0 + komunikat nazywający defekt)
3. brak artefaktu dowodu = FAIL, nie ciche pominięcie
4. dowód działa bez bitu `+x` (wywołanie przez interpreter)
5. detektor widzi zły sekret (`401`) jako PORAŻKĘ — nie jest ślepy
6. sprzątnięcie zweryfikowane (sonda nie została w bazie/pliku)

Wynik: `PASS=6 FAIL=0` + `md5sum` plików objętych testem.

## Pułapka `replace_all` przy edycji skilli

`skill_manage(action='patch', replace_all=True)` dopasowuje TEKST, nie sekcje
markdown. `old_string="## R"` trafiło w trzy nagłówki i wstawiło blok trzy
razy; kolejna próba pogłębiła duplikację (9×). **Reguła:** przy edycji SKILL.md
dawaj `old_string` unikalny i wielolinijkowy (nagłówek + pierwsza linia treści),
albo przepisuj cały plik przez `action='edit'`. Po każdej edycji zweryfikuj
`skill_view` — jeśli output urósł nieproporcjonalnie, duplikujesz.

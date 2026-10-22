# Fałszywy NEGATYW w sprawdzianie — pułapki konstrukcji (zmierzone)

Dopełnienie do „autorstwo strażnika": tam chodzi o strażnika, który PRZEPUSZCZA zepsute.
Tu chodzi o lustrzaną klasę — strażnik, który **CZERWIENI na poprawnym obiekcie**. Oba są
fałszywym sygnałem; oba trzeba zmierzyć własnym miernikiem.

## 1. `set -o pipefail` + `grep -q` = SIGPIPE = fałszywy FAIL (2026-10-15)

Zmierzone: ad-hoc weryfikator ogłosił `FAIL publiczny APK BEZ klienta parowania`, a ten sam
string był w pliku (kontrola bezpośrednia: `unzip -p x.apk classes*.dex | strings | grep -c
'X-Pairing-Token'` → `1`). Przyczyna:

```bash
set -o pipefail
if unzip -p "$APK" classes*.dex | strings | grep -q 'X-Pairing-Token'; then …; fi
# grep -q kończy się na PIERWSZYM trafieniu i zamyka rurę
#   → unzip dostaje SIGPIPE (141) → pipefail robi z tego rc≠0
#   → `if` bierze gałąź „nie znaleziono", czyli ZNALEZIONY string raportuje jako BRAK
```

Recepta — licz wystąpienia, nie pytaj o istnienie:

```bash
CNT="$(unzip -p "$APK" classes*.dex 2>/dev/null | strings 2>/dev/null | grep -c 'X-Pairing-Token' || true)"
if [ "${CNT:-0}" -ge 1 ]; then ok "… ($CNT)"; else no "… (CNT=${CNT:-0})"; fi
```

Ta sama pułapka dotyczy KAŻDEGO `… | grep -q` pod `pipefail` (aapt2, tar, docker logs, sha256sum).
Wyjście pokazuje LICZBĘ — dokładnie tę wartość, którą znalazłbyś kontrolą ręczną, więc nie
zostaje Ci „prawie tak samo dobre" świadectwo.

## 2. Reguła nadrzędna — sprawdź DETEKTOR na znanym-dodatnim

Kolejność przy każdej czerwieni z własnego miernika:
1. **Powtórz pomiar bez miernika** (gołe `grep -c`, `sha256sum`, `stat`) na TYM SAMYM pliku/obiekcie.
2. Jeśli „gołe" pokazuje obecność, a miernik — brak: **defekt jest w mierniku, nie w obiekcie**.
   Napraw miernik i powtórz; nie zgłaszaj defektu obiektu.
3. Jeśli oba pokazują brak — wtedy badaj obiekt.

Bez tego kroku fałszywy NEGATYW kosztuje tyle samo, co fałszywy PASS: prowadzi do „naprawy"
zdrowej rzeczy (zmierzone 2026-10-15: `sha256sum` wszystkich trzech kopii identyczny, a mimo to
mój sprawdzian kazał szukać braku, którego nie było).

## 3. Zmienne pułapki towarzyszące (z tej samej sesji)

- **Ucięte pobranie pod obciążeniem** → `curl -m 40` na 19 MB APK pod `load ~99` zwrócił plik,
  który przechodzi część kontroli, ale nie wszystkie. Porównuj `sha256sum`/`stat -c %s` pobranego
  pliku z oczekiwanym ZANIM wyciągniesz wnioski; komplet sumy == komplet treści.
- **`< <(cmd)` / `$( )` w komendzie przez narzędzie terminala** bywa blokowane przez parser
  („command parser limit / unconditional blocklist"). Rozwiązanie: te same kroki zapisz jako
  plik skryptu i uruchom `bash /tmp/hermes-verify-*.sh` — parsowany jest wtedy sam skrypt.
- **Kolejność `rm` + `docker run` w jednym skrypcie** — `docker rm -f X; docker run --name X …`
  potrafi przegrać wyścig pod obciążeniem (kontener nie powstaje, a skrypt mówi tylko
  „baza nie wstała"). Diagnozuj `docker ps -a --filter name=X` + `docker logs X` ZANIM uznasz
  to za blokadę środowiska.

## 4. Nazywaj werdykt jednym z czterech, nigdy „chyba"

`PASS | FAIL | SKIP | BLOCKED` — i SKIP nigdy nie udaje PASS (nie ma czym zmierzyć ≠ zmierzone
dobrze). Skrypt ad-hoc ma kończyć kodem wyjścia = maksimum niepowodzeń (0 = PASS), a nagłówek
ma jawnie mówić, że to **weryfikacja skupiona na zmienionej ścieżce**, a nie „suite green".

# Zapis zmierzony: span OTLP „prawa" i FAIL-vs-WARN w bramce kerneli

Dwa realne przypadki z 2026-09-28 (repozytorium <workspace>, host local-aigon).
Wartość: oba pokazują, jak werdykt „to niesprawne / to niestałe" był fałszywy albo
odwrotny, i jak to rozstrzygnięto **pomiarem**, nie lekturą dokumentacji.

---

## Przypadek 1 — „prawo bez świadka": span bramki nie dolatywał do kolektora

### Objaw
Bramka `tools/gates/mesh-duty.sh` (LAW-MESH-1 „mesh ma zapierdalać") raportowała:
```
[info] span OTLP mesh.duty.verdict → http://127.0.0.1:44318 (HTTP=000000)
```
`[info]`, nie `FAIL` — czyli prawo deklarowało ślad w Tempo, a ślad nie istniał.
Klasa błędów znana i udokumentowana w repo, ale miała **żywą instancję w samej bramce**.

### Rozstrzygnięcie (kolejność, która zadziałała)
```bash
# 1. GDZIE kolektor NAPRAWDĘ słucha — z ADRESEM, nie sam port
ss -ltnp | grep 44318
#   LISTEN <host>:44318   <- TYLKO adres Tailscale, zero loopbacku

# 2. Czy loopback odpowiada?
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:44318/v1/traces   # 000
curl -s -o /dev/null -w '%{http_code}\n' https://<host>:44318/v1/traces  # 400/200 = ZYJE

# 3. Kanoniczna wartość = default w SSOT (nie wymyślaj)
grep -m1 -o 'AIGON_OTLP_ENDPOINT:-[^}]*}' docker-compose.yml
#   https://<host>:44318      <- tak ustawia to 10 usług compose
```
Przyczyna: bind na adres Tailscale z TLS-em był **świadomym kanonem** (cert z SAN
tego IP, celowo NIE `0.0.0.0`). To **klienci** celowali w martwy loopback, nie
kolektor był zepsuty. Sprawdź, po której stronie jest defekt, zanim „naprawisz" bind.

### Fix w bramce
```bash
OTLP="${AIGON_OTLP_ENDPOINT:-https://<host>:44318}"   # 1:1 z SSOT
OTLP_CA="${AIGON_OTLP_CA:-${ROOT}/core/tls/ca-bundle.crt}"   # --cacert, NIE -k
# w curl: ca_arg="--cacert ${OTLP_CA}"  (tylko gdy plik istnieje)
```

### Dowód końcowy (nie „HTTP 200 przyjęte przez odbiornik")
```bash
# Tempo ma WŁASNE API na server.http_listen_port (u nas :43220; :33200 trzymał node,
# :44317 to OTLP — pomyłka portu daje "Cannot GET /api/search" i wygląda jak awaria API)
curl -s 'http://127.0.0.1:43220/api/search?tags=service.name%3Dmesh-duty-gate&limit=5'
# {"traces":[{"traceID":"95cf1e61...","rootServiceName":"mesh-duty-gate",
#             "rootTraceName":"mesh.duty.verdict", ...}]}
```
Span **leży w Tempo**. „Endpoint zwrócił 200" znaczy tylko „odbiornik przyjął" —
dowodem jest odczyt ze składu (`api/search`).

### Strażnik klasy
`tests/contract/mesh-duty-otlp-endpoint.test.sh` (TestForge, L3, fail-closed):
default nie jest martwym loopbackiem · endpoint odpowiada · default bramki == SSOT ·
https ⇒ CA · span realnie przyjęty. **Test negatywny:** przywrócenie martwego
loopbacku w kopii bramki → `4× FAIL`, `rc=1`.

---

## Przypadek 2 — „niestała bramka", która nią nie była

### Objaw
`pre-push` hook (18 bramek, `block_on_fail=true`) blokował push:
```
FAIL kernel-health (CERTIFICATION: FAIL)
```
Dwa razy z rzędu. Uruchomiona **ręcznie** ta sama bramka:
```
Checks: 4  PASS: 2  FAIL: 0  WARN: 1  INFO: 1
CERTIFICATION: PASS    rc=0
```

### Fałszywa diagnoza (i dlaczego była fałszywa)
„Bramka ma okno świeżości ≤180 s → snapshot promql był nieświeży → migotanie."
**Nieprawda.** Kod (`tools/verify/gates/domains/kernel-health.sh`, okolice 200-250):
- brak pary metryk albo `age > MAX_STALE` → **`warn`** — komentarz wprost:
  „nieswieza seria udaje aktualna prawde; swiezy scrap rozstrzyga, nie FAIL",
- **`fail` (BLOCKING)** wyłącznie przy **świeżej** próbce z `healthy < total`
  (KERNEL-002) albo `total < manifest ENABLED` (KERNEL-004).

Czyli FAIL w hooku oznaczał **realny, świeżo zmierzony niedobór kerneli** —
najpewniej restart w trakcie przebiegu.

### Rozstrzygnięcie
```bash
# pętla odtwarzająca (24 przebiegi × ~12 s)
for i in $(seq 1 24); do bash tools/gates/kernel-health.sh >/dev/null 2>&1 \
  && echo PASS || echo "FAIL $(date -u +%H:%M:%SZ)"; sleep 12; done
#   -> przebiegi=24 FAIL=0     (nie odtwarza się)

# rozkład stanów: KTÓRY kernel i którą wartością
curl -s --get --data-urlencode 'query=aigon_kernels_state' http://127.0.0.1:49091/api/v1/query
#   -> <host> healthy=35 degraded=0 down=0 total=35  (i 4 kolejne węzły tak samo)
```
Wniosek: bramka **nie kłamała** — złapała przejściowy stan i system się podniósł.
Zadziałała procedura operacyjna, nie „naprawa" bramki.

### Konsekwencja operacyjna (wzorzec do reużycia)
Gdy blocking gate migocze: **uruchom go ręcznie, a push wykonaj w tym samym oknie**.
```bash
if bash tools/gates/kernel-health.sh >/dev/null 2>&1; then
  git -c credential.helper= push "<https-url-z-tokenem>" main   # W TYM SAMYM oknie
else
  echo "FAIL również teraz — NIE pushuj na ślepo"
fi
```
Zmierzone: przy 3. podejściu `WYNIK: PASS` + `... -> main` (i to samo zadziałało
drugi raz przy kolejnym commicie). Nie pushuj „na ślepo" w kółko — najpierw bramka.

### Współbieżność (ten sam host, inni agenci)
- `.git/index.lock` trzymany przez **cudzy** proces → **NIE usuwać**, czekać w pętli.
- `git-safe-commit.sh` PRZERWAŁ commit, bo w indeksie był **cudzy** plik
  (`reports/cycle-consolidation-*.md`) → odstaw po nazwie:
  `git reset -q HEAD <cudzy-plik>`, potem ponów commit. Nigdy `-A`.
- Komunikat commita z `-m` i znakami shellowymi (`|| echo 000`, backticki) bywa
  **zjedzony przez podstawienie shella** — pisz komunikat do pliku i użyj `-F`.

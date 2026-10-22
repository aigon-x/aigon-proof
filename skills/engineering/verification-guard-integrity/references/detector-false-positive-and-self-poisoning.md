# Detektor zbyt szeroki + SAMO-ZATRUCIE SKANU (zmierzone 2026-10-13, AIGON)

Klasa: bramka/straznik FAIL-uje mimo braku realnego naruszenia, a naprawa
wzorca NATYCHMIAST tworzy nowe trafienie. Dwa podwzorce + metoda dowodu.

## Objaw wejsciowy
Bramka `law-56a-secret-channel` (GATE-139): najpierw `FAIL — transkrypty-agentow:1`,
po naprawie `FAIL — logi-procesow:3`. Zero realnych sekretow w obu przypadkach.

## Wzorzec A — regex przechodzi przez SEPARATORY polecen
```
curl[^|]*[[:space:]]-u[[:space:]]*[^:[:space:]]+:[^$"'[:space:]][^[:space:]]{3,}
       ^^^^^^ przechodzi przez ; ' " | nowa linie
```
Dopasowuje `-u` nalezace do INNEGO polecenia w tej samej linii:
```
ssh host 'curl -s -m 8 http://127.0.0.1:8311/health; echo; date -u +%Y-%m-%dT%H:%M:%SZ'
                                                            ^^^^^^ flaga `date`, nie `curl`
```
FIX: wyklucz separatory i cudzyslowy z klasy znakow akceptujacej prefiks:
```
curl[^|;'"`]*[[:space:]]-u[[:space:]]*...
```
TERAZ `-u` MUSI byc flaga TEGO SAMEGO `curl` (bez `;`/`'` pomiedzy).

## Wzorzec B — SAMO-ZATRUCIE: agent opisuje wzorzec i sam go tworzy
Bramka skanuje logi/transkrypty. Po naprawie A FAIL wrocil na `logi-procesow:3`,
a zrodlem byly WLASNE logi (auto-git/voice/inbox) cytujace TEMAT commita:
```
/var/log/aigon/aigon-voice-inbox.log: MOWA: Nowa aktualizacja: zawęź wzorzec 'curl -u user:pass', ...
/var/log/aigon/aigon-voice-ingest.log: GIT: f87b34c6 zawez wzorzec 'curl -u user:pass' — ...
```
Detektor lapie OPIS wzorca jako naruszenie -> naprawa bramki ja psuje.
FIX: (1) rozszerz liste wyjatkow o slowa-znaczniki OPISU, spojnie z istniejacym
`pattern|PATTERNS`: `wzorzec|zawez|zawęź|zawęż`; (2) NIE cytuj literalu wzorca
w temacie commita jako `'curl -u user:pass'` — pisz opisowo `wzorzec curl -u`.

REGULA OGOLNA: jesli bramka skanuje logi/transkrypty/historie, a Twoja naprawa
albo commit opisuje wzorzec — SPRAWDZ, czy nie tworzysz nowego trafienia.
Dotyczy takze: "-p <haslo>" w komendzie, ktora sama jest potem logowana.

## Metoda: wyciagnij DOKLADNY dopasowany fragment
Nie czytaj calej linii z logu — wyciagnij dopasowanie:
```
grep -oInE '<pelny-wzorzec>' <plik>      # pokazuje TYLKO dopasowany fragment
sed -n '<linia>p' <plik> | cut -c1-260   # pelny kontekst linii
```
Dopiero to rozstrzyga czy trafienie jest realne, czy to przeciek klasy znakow.

## OBOWIAZKOWY DOWOD NEGATYWNY (obustronny)
Po KAZDEJ zmianie wzorca / listy wyjatkow:
```
# 1) prawdziwe naruszenie MUSI byc zlapane (inaczej osmieliles bramke):
printf 'curl -s -u admin:<PASSWORD> https://api/x\n'   # -> MATCH
printf 'psql -p <PASSWORD> -h db\n'               # -> MATCH
# 2) falszywy traf MUSI zniknac:
printf 'date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ\n'              # -> NO MATCH
```
Obie strony razem. Sama strona "false-positive zniknal" = ryzyko zepsutej bramki.
Sama strona "realny zlapany" = brak dowodu, ze nie halasuje.

## Triangulacja: standalone vs w hooku
Uruchom bramke SAMODZIELNIE (`bash tools/gates/<id>.sh`) ORAZ zobacz raport
hook-runnera. Ten sam defekt moze raportowac ROZNE zrodla (`transkrypty-agentow:N`
vs `logi-procesow:N`) — bo skanuje rozne sciezki. Zawsze nazwij ZRODLO
(`zrodlo <label>:N`), nie tylko liczbe.

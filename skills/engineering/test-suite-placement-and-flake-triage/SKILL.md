---
name: test-suite-placement-and-flake-triage
description: "Gdzie i jak uruchamiać pełny suite/CI (local vs dedykowany builder), jak odróżnić flake od realnego FAIL i jak dowieść wyniku. Użyj, gdy `npm run test`/`make test` przekracza limit czasu, gdy suite pada tylko pod obciążeniem, gdy wynik ma być dowodem (evidence), albo gdy przenosisz testy na inną maszynę i dostajesz fałszywe czerwienie."
---


# Miejsce uruchamiania suit i triage flaków

Klasa zadania: masz kanoniczną komendę testów (`npm run test`, `make test`), a jej wynik
ma być **dowodem** — albo chcesz ją przenieść z laptopa na builder/CI. Ten skill odpowiada
na trzy pytania: **gdzie**, **jak długo** i **czy FAIL jest prawdziwy**.

## 1. Dowód zapisuje tylko przebieg pierwszoplanowy

`terminal(background=True)` **nie rejestruje** wyniku jako evidence — status zostaje
`stale`, mimo że w logu jest `SUITE: PASS`. Jeśli potrzebujesz dowodu: uruchom
**foreground** z `timeout <= 600`.

Konsekwencja praktyczna: jeśli suite trwa dłużej niż limit, nie „przenieś do tła" —
**skróć albo przenieś na inną maszynę** (patrz pkt 3) i tam uruchom foreground.

Zmierzone: ten sam suite trwał **6–7 min** przy load ~26–40 i **15–20 min** przy load 70–140
(24 rdzenie). Czas jest funkcją obciążenia hosta, nie rozmiaru kodu — zawsze podawaj load
razem z czasem.

## 2. Flake czy FAIL — rozstrzygaj, nie zgaduj

Procedura (3 kroki, każdy tani):

1. **Uruchom pojedynczy test w izolacji 3–5×.** PASS 5/5 przy tym samym drzewie = flake
   środowiskowy; FAIL 1/5 = realny defekt (migotliwy kod).
2. **Nazwij mechanizm wyścigu.** Zmierzone przypadki:
   - test porównuje SSOT z plikiem renderowanym **atomowo** (`sync-cron.py` → `rename`
     na `/etc/cron.d/...`) i trafia w okno podmiany → `DRYF SSOT->cron` bez realnego dryfu;
   - test czyta plik, który inny agent edytuje w tej samej sekundzie (współdzielone repo).
3. **Utwardź test, nie wyciszaj.** Retry z sleep jest legalny, gdy dotyczy **okna
   atomowego zapisu**, nie treści: `for 1..5: check && break; sleep 3`. Realny dryf
   nadal FAIL-uje po 5 próbach — to nie waiver. (Zmierzone: 3×2 s nie wystarczyło,
   5×3 s = 15 s okna — wystarczyło.)

Czego NIE robić: nie zmieniaj progu, nie dodawaj `|| true`, nie oznaczaj jako skip.
Flake naprawiony przez wyciszenie wraca jako fałszywy zielony.

## 3. Przenoszenie suite na builder/CI — najpierw profil CI

Suite „fast" bywa **sprzężony z hostem**. Zmierzone na czystej VM builder
(Debian 13, 8 vCPU, bez systemd/docker-state): **13/26 PASS, 5 FAIL, 8 ERROR**, m.in.
`root/HOME=/root: FAIL → fałszywa czerwień wróciła` i testy bez `tf_exit`
(„FALSE GATE: brak test-results.json").

Wniosek: przeniesienie suite na inną maszynę **bez profilu CI** przenosi fałszywe
czerwienie. Kolejność: (a) zinwentaryzuj, które testy dotykają systemd/docker/`/etc`/HOME,
(b) przygotuj profil (docker socket, fixtures HOME, jednostki systemd albo mocki),
(c) dopiero potem ogłoś „CI na builderze".

### Sync repo na builder — dwie pułapki

- **`rsync --delete` na całe repo KASUJE katalogi, które builder ma własne**
  (u mnie `sigil/`, `runtime/`, `governor/`). Synchronizuj **jawną listę katalogów**
  (`tools tests scripts config package.json`) bez `--delete`.
- **Nie syncuj wielkich productów** (`products/*` po kilka GB) — sync przekraczał 40 min
  i był ubijany przez `timeout`. Testy rdzenia ich nie potrzebują; testy produktowe
  uruchamiaj tam, gdzie produkt żyje.
- `--checksum` na ~900 MB plików to 20–30 min; `mtime+size` wystarcza, jeśli nie
  podejrzewasz cichej podmiany treści.

## 4. Raportowanie wyniku

Podawaj **trzy** liczby: `Total / PASS / FAIL` + czas + load hosta. „Suite green"
bez liczby przebiegów jest niedowodem. Gdy 1 test jest flakiem: napisz to wprost
(`25/26, FAIL=flake X, izolowanie 5/5 PASS`) — nie zaokrąglaj do „wszystko działa"
ani nie ogłaszaj „wszystko czerwone".

## Pułapki

1. **Background run ≠ evidence** — status zostaje `stale`.
2. **`timeout` na komendzie testów obcina przebieg, ale `rc` bierze się z ogona pipe'a**
   (`| tail`) → `rc=0` przy przerwanym teście. Mierz `PIPESTATUS` albo bez pipe'a.
3. **Load > rdzenie** wydłuża suite 2–3× i generuje flaki timeoutowe — zanim uznasz test
   za zepsuty, sprawdź `/proc/loadavg`.
4. **Izolowany test PASS nie unieważnia FAIL-a z pełnego biegu** — musi istnieć nazwany
   mechanizm wyścigu, inaczej to nadal defekt.
5. **Suite nie może „sama się naprawić"** retry'em w nieskończoność — limit prób i sleep
   muszą być w kodzie testu, widoczne w diffie.

## Powiązane

- `cdp-browser-raw-control` — gdy dowodem ma być zrzut/odczyt DOM, nie test.
- `verification-guard-integrity` — projektowanie strażników i bramek, dowód negatywny.
- `aigon-testforge-verify-audit` — anatomía TestForge (`tf_exit`, `test-results.json`).

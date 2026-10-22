---
name: deployment-effect-verification
description: >-
  Użyj, gdy trzeba DOWIEŚĆ, że zmiana dotarła do działającego systemu (a nie tylko
  „build Finished"/„kontener Up"): łańcuch tożsamości artefaktu (źródło → binarka →
  obraz → proces), dowód SKUTKU w runtime, okno bootu po recreate, oraz rozróżnienie
  zmiany w binarce od zmiany w konfiguracji. Zawiera KOREKTĘ reguły „strings=0 znaczy,
  że kod nie wszedł" (fałszywy alarm, zmierzony 2026-10-17) i pułapki pomiaru, które
  kosztują jedno okrążenie każda.
version: 1.0.0
author: Sniegul (AIGON-X)
license: MIT
metadata:
  hermes:
    tags: [deployment, verification, binary, docker, false-green, runtime, evidence]
    related_skills:
      - aigon-runtime-build-deploy-truth
      - runtime-health-graph-audit
      - gate-layer-audit
      - false-green-elimination
---


# Weryfikacja EFEKTU wdrożenia (nie wdrożenia)

## Po co

„Build Finished", „Obraz zbudowany", „Kontener Up (healthy)" to **zdarzenia**, nie dowody.
Dowodem jest **skutek widoczny w działającym systemie**. Ten skill opisuje łańcuch dowodu
dla zmiany kodu/konfiguracji oraz cztery pułapki, które dają fałszywy obraz w OBIE strony
(zarówno „wdrożone", gdy nie jest, jak i „nie wdrożone", gdy jest).

## Łańcuch dowodu (każde ogniwo osobno, wszystkie obowiązkowe)

```
1. ŹRÓDŁO      mtime zmienionego pliku
2. LIB         mtime target/release/deps/lib<crate>-*.rlib   > mtime źródła
3. BINARKA     mtime target/release/<bin>                    > mtime źródła
4. OBRAZ       md5 <bin> w obrazie == md5 z target/release
5. PROCES      md5 /usr/local/bin/<bin> w kontenerze == md5 obrazu
6. SKUTEK      odpowiedź runtime (JSON/endpoint/log) pokazuje nowe zachowanie
```

Kroki 1-5 dowodzą **tożsamości** artefaktu. Dopiero krok 6 dowodzi **działania**.
Bez kroku 6 raport brzmi „wdrożone" na podstawie hashy — a hash nie mówi, czy kod robi
to, co miał.

## KOREKTA: `strings` jest dowodem tylko w JEDNĄ stronę

- `strings <bin> | grep -c '<napis>'` **> 0** ⇒ kod wszedł. To dowód dodatni.
- **Zero NIE dowodzi, że kod nie wszedł.** Zmierzone 2026-10-17: dodany klucz JSON
  `"instrumentation"` (handler `/api/v1/self/components`) dawał `strings`=0 **oraz**
  `grep -a`=0 w świeżej binarce — a runtime po wdrożeniu **zwracał to pole** dla 46/46
  komponentów. Literały bywają scalane z sąsiednimi; klucze JSON nie zawsze leżą jako
  samodzielny ciąg.
- Skutek błędu: agent ogłasza „kod nie wszedł" i planuje kolejny 26-minutowy rebuild
  **bez potrzeby**. Zanim to zrobisz: sprawdź krok 2 (rlib) i krok 6 (odpowiedź runtime).

## Pole konfiguracyjne ≠ pole binarne

Zanim zaplanujesz rebuild, ustal, **czym** steruje brakujące zachowanie:

```bash
grep -rn '<pole>' <bin_crate>/src/main.rs <lib_crate>/src/lib.rs
```
Zmierzone: `theory_dir` miało `None` w `aigon-core/src/lib.rs:306`, a binarka ustawiała je
**wyłącznie z pliku konfiguracji** (`aigon-runtime-bin/src/main.rs:244`), bez wiązania env.
Endpoint zwracał `503 TheoryRegistry not configured` przy zdrowym runtime — naprawa to
**wpis w configu + recreate**, nie przebudowa binarki (oszczędzone 26-28 min).

Pułapka loaderów: `load_from_path(p)` potrafi **delegować** do `load_from_theory_dir(p)`,
które samo dokleja nazwy plików. Podanie PLIKU dało `Not a directory (os error 20)`.
Reguła: przeczytaj, co funkcja robi z argumentem, zanim podasz ścieżkę.

## Okno bootu: `/health` kłamie „gotowe" (zmierzone ~110 s)

Po `--force-recreate` runtime zwraca:
- `GET /health` = **200**, `boot_phase: running`,
- `GET /api/v1/kernels` = **503** `runtime_boot_in_progress`.

`docker ps` pokazuje `Up (healthy)` przez cały ten czas (healthcheck pyta `/health`).
Weryfikuj **API**, nie `/health`:

```bash
for i in $(seq 1 20); do
  code=$(curl -sk -m 8 -o /dev/null -w '%{http_code}' -H "X-API-Key: $S" \
         https://localhost:7000/api/v1/kernels)
  echo "proba $i: $code"; [ "$code" = "200" ] && break; sleep 10
done
```
Zmierzone: 11 prób × 10 s. Odpytanie `/health` i ogłoszenie sukcesu = fałszywy zielony.

## `docker compose restart` NIE czyta nowego obrazu

Restart używa konfiguracji z momentu `create`. Zawsze
`docker compose -p <proj> up -d --force-recreate --no-deps <svc>`, a potem krok 5 i 6.
Kontener może też działać na starym obrazie mimo świeżego `docker image inspect` — hash
binarki w środku jest jedynym rozstrzygnięciem.

## Edycja plików w drzewie współdzielonym: PermissionError ≠ „patch nie zadziałał"

W `<workspace>` pliki bywają `aigon:aigon 0644`, a cron „napraw uprawnienia" przestawia
właściciela co ~20 min — **w trakcie** serii edycji. Wzorzec odporny: przed każdą serią
`sudo -n chown sniegul:aigon <plik>`, po zapisie `chmod 644` (skrypty `755`).
Objaw mylący: „patch nie zadziałał" — w rzeczywistości zapis się nie odbył (sprawdź
`grep -c '<nowy tekst>' <plik>`).

## Uruchamianie długich weryfikacji

Suite może trwać **7-8 min** (rośnie z rozmiarem grafu/repo). Limit 590 s na komendę
w tle **nie jest** porażką testów — uruchamiaj
`terminal(background=true, notify_on_complete=true)` i czytaj wynik końcowy, nie pierwszy
timeout. Analogicznie build release: 26-28 min na 2 rdzeniach (`-j2`) jest normalny.

## Checklista

- [ ] mtime źródła → rlib → binarka (rosnąco)
- [ ] md5 binarki == obraz == proces
- [ ] SKUTEK widoczny w odpowiedzi runtime (nie tylko w logu startowym)
- [ ] boot: czekanie na API (`/api/v1/kernels`), nie na `/health`
- [ ] ustalone, czy zmiana miała być w binarce, czy w configu (`grep` po `main.rs`)
- [ ] żaden wniosek nie opiera się na `strings`=0

## Powiązane

- `aigon-runtime-build-deploy-truth` — mapa crate'ów lib vs bin i procedura AIGON-X.
  UWAGA: jej pitfall #7 twierdzi „`strings`=0 ⇒ kod nie wszedł" — **jest to błędne**
  (patrz KOREKTA wyżej); skill jest ręcznie utrzymywany, więc korekta żyje tutaj.
- `runtime-health-graph-audit`, `gate-layer-audit` — mierzenie pokrycia i fałszywych
  zieleni w warstwie kontroli.

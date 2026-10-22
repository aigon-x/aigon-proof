---
name: release-artifact-truth
description: >-
  Dowód tożsamości artefaktu wydania (APK / bundle / obraz / wagi): JEDEN manifest
  jako źródło (wersja + nazwa pliku + sha256 + rozmiar), potem asercja
  manifest == config == dysk == publiczny URL po bajtach. Użyj, gdy publikujesz
  albo weryfikujesz wydanie i musisz odpowiedzieć „to jest TO wydanie", a nie
  „HTTP zwróciło 200".
category: devops
triggers:
  - weryfikacja wydania / releasu / artefaktu do pobrania
  - czy sklep / landing / API podaje aktualną wersję
  - sha256 APK / bundle / image digest nie zgadza się
  - curl 200 ale plik jest stary albo to strona błędu
  - brief/runbook żąda nieaktualnego numeru wersji
---


# Artefakt wydania: dowód z bajtów, nie z kodu HTTP

## Kiedy używać

- Publikujesz lub weryfikujesz wydanie, które użytkownik **pobiera** (APK, ZIP, bundle,
  obraz kontenera, wagi modelu).
- Ktoś (brief, runbook, ticket, poprzedni agent) podaje numer wersji i oczekuje, że
  „poprawisz" config, żeby go pokazywał.
- `curl` wraca 200, a nie jesteś pewien, **co** właściwie wróciło.

## Zasada nadrzędna

> **Tożsamość artefaktu = jedno źródło. Dowód = bajty z celu.
> Numer wersji w czyimś tekście to hipoteza, nie prawda.**

Trzy prawdy, które muszą się zgadzać **jednocześnie**:

```
manifest (release.json / *.json / digest)  ==  config publikujący (yaml/db)
        ==  plik na dysku (sha256 + rozmiar)  ==  publiczny URL (bajty)
```

Brak któregokolwiek ogniwa = „nie zmierzone", nie „OK".

## Procedura

1. **Znajdź manifest, nie numer w tekście.** `rg --files -g 'release.json' <repo>`;
   dla obrazów `docker inspect --format '{{index .RepoDigests 0}}'`. Manifest niesie
   `versionName`, nazwę pliku, `sha256`, `builtAt` — i to on jest SSOT.
2. **Złóż URL wyłącznie z manifestu**: `https://<host>/app/<manifest.apk>`.
   Nigdy „wersja stąd + hash stamtąd" (patrz Pułapka 1).
3. **Zmierzone na dysku**: `sha256sum` + `stat -c%s` pliku, który realnie zostanie wydany.
   Musi równać się `manifest.sha256`.
4. **Pobierz publicznie z `-f` i asercją typu**:
   ```bash
   curl -fsS -o /tmp/a.bin -w '%{http_code} %{content_type} %{size_download}\n' "$URL"
   # 200 | application/vnd.android.package-archive | <bajty == stat -c%s>
   ```
5. **Config publikujący** (`produkty.yaml`, `.env`, katalog wersji) — porównaj z manifestem,
   patchuj **wszystkie sprzężone pola razem** (wersja, URL, rozmiar, wpis dowodowy).
6. **Zbuduj + opublikuj**, potem **zmierz publicznie z cache-busterem** i asercją
   href-a: `curl -sk "https://host/page/?cb=$(date +%s)" | grep -o '<href>'`.
7. **Sonda ad-hoc** (nie „suite green"): gotowy skrypt `scripts/verify-release-artifact.py`
   robi kroki 2–6 w jednym przebiegu i zwraca kod wyjścia ≠ 0 przy rozjeździe.

## Pułapki (wszystkie zmierzone)

### 1. Nazwa sklejona z dwóch źródeł = 404, który wygląda jak sukces
2026-10-17, sklep INORG: brief żądał `4.0.6`, bieżący manifest miał hash `0a61cc4e…`.
Powstał `pluskwa-4.0.6-0a61cc4e8cd5b8f3.apk` — kombinacja, której **nigdy nie było**
→ `HTTP 404`, 1084 B, `text/html`. Wersja z tekstu + hash z manifestu to nie artefakt,
to wymysł. Nazwę pliku bierz **tylko** z manifestu.

### 2. `curl -s -o` bez `-f` — hash strony błędu jako „dowód"
Ten sam przypadek: pobranie „się udało" (exit 0), plik miał 1084 B i był HTML-em
`<title>404 Not Found</title>`. Jego `sha256` trafił do meldunku jako dowód APK.
Zawsze `-f`, zawsze `content_type`, zawsze porównanie `size_download` z rozmiarem na dysku.

### 3. HTTP 200 nie dowodzi aktualności
Stare wydanie (`4.0.6-…`, 13 194 028 B) leżało dalej na serwerze i wracało **200
z poprawnym `application/vnd.android.package-archive`**. Aktualność = zgodność
z manifestem; kod odpowiedzi mówi tylko „plik istnieje".

### 4. Rozmiar w MB z opisu, nie z bajtów
`round(bajty/1048576, 2)` — 13 952 923 B → `13.31`. Wpis w configu liczony „na oko"
albo przepisany z poprzedniego wydania przechodzi przegląd i kłamie w UI.

### 5. `deploy.sh` / `rsync` exit 0 ≠ opublikowane
Build lokalny bywa osobnym torem niż produkcja. Weryfikuj publiczny URL z `?cb=`,
czytaj `cf-cache-status`, a przy HA — osobno origin na węźle. (Szczegóły:
`deploy-verification-not-rsync-exit`; dla sklepu INORG topologia prod-aigon /
contabo-aigon + `family-ha-deploy.py` są w `inorg-landingfull-update`.)

### 6. Zgnity literał w briefie/runbooku
Kryterium „`grep -c 'Pobierz dla Androida (4.0.6)'` > 0" przeżyło 35 wydań.
Test akceptacyjny formułuj jako **porównanie z manifestem**, nigdy jako literał.

## Gdy brief przeczy pomiarowi — koryguj dokument, nie tylko kod

Wykonanie zgnitego briefu dosłownie **degraduje produkcję** (tu: sklep z 4.0.41 na
4.0.6 + link do nieistniejącego pliku). Po wykryciu:

1. **Cofnij do zmierzonej prawdy z manifestu** — nie do „poprzedniego commita"
   (poprzedni commit mógł nieść ten sam błąd).
2. **Wpisz do dokumentu datowaną KOREKTĘ POMIARU** nadpisującą literał:
   `> ⚠️ KOREKTA 2026-10-17: <manifest> → 4.0.41; nie poprawiać w dół do 4.0.6 (404).`
   Bez tego pętla cron za 30 min wykona znowu zgnitą instrukcję. Poprawka w kodzie
   bez poprawki w dokumencie to leczenie objawu.
3. **Wycofaj fałszywy dowód wprost w raporcie**: który plik, jaki hash, dlaczego to był
   HTML 404, który commit/deploy to rozniósł. Przemilczany fałszywy alarm zatruwa
   następnego agenta i wraca jako „regresja".

## Checklista przed „gotowe"

```
[ ] manifest odczytany (wersja, plik, sha256, builtAt) — nie z tekstu briefu
[ ] sha256 + rozmiar pliku na dysku == manifest
[ ] publiczny URL: 200 + poprawny content-type + size_download == rozmiar z dysku
[ ] config publikujący: href == https://<host>/app/<manifest.apk>, rozmiar = round(B/MiB,2)
[ ] build + publikacja (tor produkcyjny, nie tylko lokalny build)
[ ] publicznie z ?cb=: etykieta i href == manifest, zero martwych numerów
[ ] commit w osobnym repo źródła (tylko własny plik, nie `git add -A`)
[ ] brief/runbook: literał nadpisany datowaną korektą, jeśli przeczył pomiarowi
```

## Support files

- `scripts/verify-release-artifact.py` — sonda ad-hoc: manifest ↔ config ↔ dysk ↔ HTTP
  ↔ wyrenderowany dist; 13 asercji, exit ≠ 0 przy rozjeździe.
- `references/stale-brief-vs-manifest-2026-10-17.md` — pełny zapis przypadku (pluskwa:
  4.0.6 vs 4.0.41, 404 z 1084 B, dwa commity i dwa deploye fałszywego wydania, procedura
  cofnięcia i korekty dokumentu).

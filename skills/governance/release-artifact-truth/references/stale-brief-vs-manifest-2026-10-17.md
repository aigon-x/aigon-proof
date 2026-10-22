# Zgnity brief vs manifest — pluskwa 4.0.6 → 4.0.41 (zmierzone 2026-10-17)

Zapis przypadku klasy „runbook niesie nieaktualny literał, agent wykonuje go dosłownie
i degraduje produkcję". Wartość: pokazuje **łańcuch** fałszywego dowodu i procedurę wyjścia.

## Wejście

Pętla cron co 30 min, rozkaz: „dokończ PEŁNĄ MOC z `<workspace>/go.md`".
W rozkazie stan zamknięty z 2026-10-01 z kryterium:

```
curl -sk https://inorg.szamani.ai/produkty/ | grep -c 'Pobierz dla Androida (4.0.6)'  > 0
link: https://pluskwa.szamani.ai/app/pluskwa-4.0.6-cdf0b62a7fbd5037.apk
```

## Prawda zmierzona (2026-10-17)

```
/opt/projects/inorg/pluskwa/app/release.json
  versionName 4.0.41 | versionCode 62 | apk pluskwa-4.0.41-0a61cc4e8cd5b8f3.apk
  sha256 0a61cc4e8cd5b8f3ff88f222d690f696bb92bb06d9d646c0d0ac0db94aa47dc2 | 2026-10-16T23:36Z

sha256sum  pluskwa-4.0.41-…apk  ==  pluskwa-latest.apk  ==  0a61cc4e…
stat -c%s  13952923 B  (13.31 MiB)

HTTP  /app/pluskwa-4.0.41-0a61cc4e8cd5b8f3.apk -> 200, application/vnd.android.package-archive, 13952923 B
HTTP  /app/pluskwa-4.0.6-cdf0b62a7fbd5037.apk  -> 200, application/vnd.android.package-archive, 13194028 B  (stare wydanie, nadal lezy)
HTTP  /app/pluskwa-4.0.6-0a61cc4e8cd5b8f3.apk  -> 404, text/html, 1084 B  (kombinacja, ktorej nie bylo)
```

W 16 dni między briefem a pomiarem poszło 35 buildów (4.0.27 → 4.0.41). Literał z 1.10
był więc o pół setki wydań do tyłu — a mimo to wyglądał „autorytatywnie", bo stał w rozkazie.

## Łańcuch fałszywego dowodu (to jest sedno)

1. Agent wziął wersję `4.0.6` **z briefu** i hash `0a61cc4e…` **z manifestu** bieżącego
   wydania → złożył URL, który nigdy nie istniał.
2. `curl -s -o /tmp/pluskwa-4.0.6.apk <404-url>` zwrócił **exit 0** (brak `-f`), zapisując
   1084-bajtową stronę `404 Not Found` (nginx).
3. `sha256sum` tej strony (`fe2f7998…`) trafił do meldunku jako **dowód APK** — liczba
   prawdziwa, wniosek fałszywy. Klasyk: mierzone jest to, co przyszło, nie to, co miało przyjść.
4. Dwa commity (`a004e97`, `142ad2c`) + dwa deploye (`25 pages`, `6/6 headers`, `85 CF files`)
   ogłosiły wydanie, którego nie ma; na produkcji przez ~20 min wisiał przycisk do 404.
5. Publiczny `grep` wciąż pokazywał stary HTML → agent dopisał to jako „cache" zamiast
   sprawdzić, czy **nowy** URL w ogóle istnieje.

## Wyjście (procedura, która zadziałała)

1. **Manifest jako jedyne źródło** — `release.json` dał wersję, nazwę, hash i rozmiar.
   Dopiero wtedy „4.0.6" okazało się nie regresją sklepu, a moim wymysłem.
2. **Cofnięcie do zmierzonej prawdy**, nie do poprzedniego commita (poprzedni commit był
   już mój i błędny): `apk_wersja 4.0.41`, `apk …4.0.41-0a61cc4e…apk`, rozmiar `13.31`,
   wpis `status_dowod` z „APK 4.0.41 … HTTP 200".
3. **Build + deploy**, potem **publicznie z cache-busterem**:
   ```
   /produkty/          cf-cache-status: DYNAMIC | href 4.0.41 | martwy 4.0.6: 0 | MESH hasło: 1
   /produkty/pluskwa/  cf-cache-status: DYNAMIC | href 4.0.41 | martwy 4.0.6: 0
   ```
4. **Sonda ad-hoc** (13 asercji, `/tmp/hermes-verify-XXXXXX.py`, `mktemp`): YAML ↔ manifest
   ↔ HTTP ↔ wyrenderowany `dist` — 13/13 PASS, jawnie opisana jako ad-hoc, nie „suite green".
5. **Datowana korekta w dokumencie rozkazu** (`<workspace>/go.md`, FAZA 1): blok
   „⚠️ KOREKTA POMIARU 2026-10-17" nadpisujący literał 4.0.6 i zakazujący „poprawiania
   w dół". Bez tego następny cykl o 23:55 powtórzyłby degradację —
   **poprawka w kodzie bez poprawki w dokumencie leczy objaw**.
6. **Jawne wycofanie w raporcie**: trzy twierdzenia (fałszywe „GO.MD ZAKOŃCZONE",
   hash strony 404 jako dowód APK, „regresja sklepu") — każde z komendą i wynikiem.

## Wnioski do stosowania

- Kryterium odbioru pisz jako **porównanie z manifestem**, nigdy jako `grep '<literał>'`.
- Każdy pobrany artefakt: `curl -f` + `content_type` + `size_download` == `stat -c%s`.
- HTTP 200 to „plik istnieje", nie „plik jest aktualny" — stare wydania zostają na serwerze
  i wracają 200 z poprawnym typem.
- Gdy brief przeczy pomiarowi: koryguj **dokument** (datowanym blokiem), nie tylko config;
  inaczej automat powtórzy błąd co cykl.

---
name: agent-artifact-hygiene
description: Użyj, gdy agent (lub subagent) tworzy artefakty pracy — surowe źródła, ekstrakty API, logi zwiadowców, raporty — i trzeba zdecydować, GDZIE one mają żyć, żeby przetrwały. Obejmuje rozdział /tmp vs repo, bramkę „artefakt ma dom w repo", diagnozę dlaczego /tmp miesza dowód z odpadem, reguły sprzątania cudzych artefaktów oraz przypadek utraty dowodu przez zwiadowcę swarmu. Rozkaz źródłowy — nie masz sprzątać, masz pomyśleć co zrobić, żeby nie było bałaganu. Użyj gdy zadanie dotyczy — Użyj, gdy agent (lub subagent) tworzy artefakty pracy.
---


# Higiena artefaktów agenta — gdzie ma żyć produkt pracy

Klasa zadania: **agent tworzy coś trwałego** (pobrał źródła, wygenerował raport,
zrobił zrzut API, subagent zostawił ekstrakt) i trzeba rozstrzygnąć, gdzie to ma
dom, żeby nie zginęło przy pierwszym sprzątaniu.

## Zasada nadrzędna (rozkaz Suwerena, 2026-09-28)

> „ty nie masz sprzątać, ty masz pomyśleć co zrobić żeby nie było bałaganu"

Sprzątanie `/tmp` to usuwanie SKUTKU. Celem jest zamknięcie KLASY problemu:
tak zaprojektować przepływ, żeby dowód nigdy nie wylądował w katalogu ulotnym.
Zgłaszaj rozmiar i wiek, ale decyzję o usunięciu cudzego artefaktu podejmuje WŁAŚCICIEL.

## Zdarzenie wyzwalające (zmierzone)

Zwiadowca swarmu pobrał **192 KB pierwotnej dokumentacji** (14 plików `docs.typesafe.ai`)
do `/tmp`, a syntezę zapisał w repo. Zostawił w `/tmp` **DOWÓD ŹRÓDŁOWY**.

Dlaczego to jest groźne: patrząc na `df`/`du -sh` widzi się ROZMIAR. `ts_api.md` waży
11 KB — w rankingu „sprzątaj od największych" ginie pierwszy. Utrata dowodu nie boli
natychmiast; boli przy audycie, gdy trzeba odpowiedzieć „skąd to wiemy".

## Dlaczego `/tmp` jest STRUKTURALNIE złym nośnikiem

1. **Domyślny ścieg wszystkich narzędzi.** `mktemp`, buildy, `nohup > /tmp/…`,
   zwiadowcy piszący „na boku" — nikt tego nie projektuje, to się dzieje samo.
   Dlatego samo „posprzątaj /tmp" nie jest środkiem: za godzinę będzie nowy `/tmp`.
2. **Miesza DOWÓD z ODPADEM w jednym katalogu.** Metryka dostępności (rozmiar, wiek)
   nie mówi nic o wartości.
3. **Wiedza umiera cicho, bo narzędzia są wygodniejsze niż dyscyplina.** Źródło ląduje
   w `/tmp`, synteza w repo → **synteza bez dowodu**, czyli twierdzenie bez możliwości
   sprawdzenia. To odwrotność „self-report is not proof": mamy raport, zgubiliśmy materiał.

## Rozdział przestrzeni — reguła operacyjna

| Katalog | Charakter | Wolno czyścić |
|---|---|---|
| `/tmp` | zwykle ulotne; lokalizacja nie przesądza własności ani wartości | tylko własne, dokładnie zidentyfikowane odpady po sprawdzeniu dowodów i aktywnych procesów |
| `/var/tmp` | dłużej żyjące; może zawierać cudze dowody | te same warunki, nigdy zbiorczo po samej lokalizacji |
| `docs/`, `audit/`, `reports/` w repo | **DOWODY** — surowe źródła, ekstrakty, zrzuty API | NIE |

**Konsekwencja:** cytowany dowód musi mieć trwały, wskazany dom przed raportem.
Publiczne, sprawdzone pod kątem sekretów artefakty mogą trafić do repo.
Sekrety, prywatne sesje, bazy i ich backupy pozostają w zatwierdzonym prywatnym
magazynie poza Git (katalog 0700, plik 0600 lub kanoniczna polityka dostępu);
w repo wyłącznie zredagowany opis weryfikacji. Odsyłacz do `/tmp/…` nie jest
trwałym zabezpieczeniem dowodu. Nigdy nie przenoś sekretów do repo dla zgodności
z zasadą „artefakt ma dom”.

Rozszerzenie reguły repo „w raporcie podawaj przeczytane ścieżki":
**podawaj ścieżki TRWAŁE, nie `/tmp`.**

## Kolejność obowiązkowa dla zadania badawczego

```
1. Pobierz źródło  → OD RAZU do repo: docs/design/<temat>-raw/
2. Zsyntetyzuj     → docs/design/<temat>.md, z odsyłaczem do raw/
3. Dopiero teraz   → /tmp wolno czyścić
```

Nigdy odwrotnie. Synteza bez surowego źródła w repo = twierdzenie bez dowodu.

## Bramka: `tools/verify/artifact-home.sh` (wdrożona w <workspace>)

Sprawdza, czy pliki w `/tmp` pasujące do znanych wzorców mają odpowiednik w repo.
Uruchamiaj PRZED każdym sprzątaniem:

```bash
bash <workspace>/tools/verify/artifact-home.sh          # raport (read-only)
bash <workspace>/tools/verify/artifact-home.sh --fail   # exit 1 gdy coś wisi
```

**Ograniczenie, które trzeba nazwać:** bramka działa na LIŚCIE ZNANYCH wzorców —
nowego typu artefaktu nie zna, dopóki ktoś go nie dopisze. To siatka na udokumentowane
przypadki, nie pełne rozwiązanie.

### Pitfall przy PISANIU takiej bramki — nakładające się wzorce

Wystąpił i został naprawiony: wzorce mogą łapać ten sam plik (`ts_*.md` i `*jev*.md`),
więc bez deduplikacji jeden plik zgłasza się RAZ jako „ma dom" i RAZ jako „sierota".
**Fałszywy alarm jest gorszy niż brak bramki.** Kluczuj po pełnej ścieżce w tablicy
asocjacyjnej (`declare -A SEEN`), zanim policzysz wynik.

### Walidacja bramki — obowiązkowy test dwustronny

Bramka, która nigdy nie pada, nie jest bramką. Sprawdź OBA kierunki:

```bash
bash <bramka> --fail; echo "stan bieżący (oczek. 0): $?"
touch /tmp/<wzorzec>-sierota.md
bash <bramka> --fail; echo "z sierotą (oczek. 1): $?"
rm -f /tmp/<wzorzec>-sierota.md
bash <bramka> --fail; echo "po sprzątaniu (oczek. 0): $?"
```

Plus detektory statyczne: `bash -n` i `shellcheck -S warning` (ten drugi znalazł realny
dług: zadeklarowaną i nigdy nieużywaną tablicę `SUSPECT_DIRS`).

## Przed `rm` w `/tmp` — dwa pytania obowiązkowe

1. **Czy to ma odpowiednik w repo?** (bramka wyżej)
2. **Czy nazwa sugeruje CELOWE zachowanie?** `*corrupt*`, `*audyt*`, `*verify*`,
   data w nazwie — np. `/tmp/ak-next-corrupt-20260924-192938` (310 MB) to zachowany
   dowód do diagnozy. Usunięcie = zniszczenie dowodu.

**Zasada nadrzędna:** decyzję o usunięciu CUDZEGO artefaktu podejmuje WŁAŚCICIEL.
Zgłoś z rozmiarem i wiekiem. Uzasadnienie usunięcia musi być dostateczne do
zignorowania pozostałego stanu.

## Artefakty subagentów — szczególny przypadek

Zwiadowcy/subagenty zostawiają ślady w TRZECH miejscach i trzeba je rozróżnić:

| Miejsce | Co tam jest | Czy dowód |
|---|---|---|
| log live (`cache/delegation/live/<id>/task-N.log`) | pełny trace wywołań i „final" | pośredni — zawiera ustalenia |
| summary (`cache/delegation/subagent-summary-*.txt`) | raport końcowy, bywa **obcięty** | tak, ale sprawdź czy nie ucięty |
| pliki w `/tmp`, które subagent utworzył | surowe źródła, ekstrakty | **TAK — najczęściej NIEZABEZPIECZONE** |

**Lekcja:** raport subagenta wraca jako summary (może być obcięty do kilku KB),
ale jego SUROWE artefakty zostają w `/tmp` bez opieki. Gdy subagent raportuje
„utworzone pliki: X, Y, Z" — sprawdź własność i wrażliwość, następnie zabezpiecz
publiczne dowody w repo, a prywatne w zatwierdzonym magazynie poza Git, zanim
cokolwiek posprzątasz. Synteza nie zastępuje źródła.

**Awaria dostawcy modelu nie unieważnia pracy subagenta.** Zwiadowcy w tej sesji padli
na HTTP 402 (brak kredytów) — siedmiu z siedmiu. Mimo to **cztery deliverable były już
na dysku**, a ustalenia z pięciu kolejnych były w logach live. Zanim uznasz swarm za
stracony: przeczytaj logi live i sprawdź `git status` / `ls` pod ścieżkami, które
subagenci raportowali. Odzysk z logów: wyciągnij bloki `assistant|`/`final`
regexem po znaczniku czasu i złóż z nich raport.

## Preferencja Suwerena: WYNIK MA BYĆ WIDOCZNY W CZASIE RZECZYWISTYM

> „czemu wpadaja opoznione informacje przeciez" / „to powinno byc realtime"

To NIE jest uwaga estetyczna. Powód, dla którego to boli: **Suweren nie ma wglądu
w pracę agenta, dopóki ten nie skończy tury.** Przy 30-minutowym buildzie awaria
w 3. minucie jest zgłaszana po 30 minutach. To luka w NADZORZE nad jego systemem.

**Mechanizm opóźnienia (zmierzony, nie domysł):** powiadomienia o procesach w tle
nie są strumieniowane — agent je buforuje i wstrzykuje do rozmowy dopiero gdy
zwolni turę (przy następnym wywołaniu narzędzia). Długie `sleep`-y po 500 s
wstrzymują całą serię powiadomień, które potem wpadają lawiną z historią sprzed godzin.
Wygenerowane zostały w chwili śmierci procesu — opóźniona jest DOSTAWA, nie zdarzenie.

**Reguły, które to eliminują:**

| Rodzaj procesu | Jak uruchamiać | Dlaczego |
|---|---|---|
| Krótki, skończony (<2 min): instancja testowa, jednorazowy probe | `timeout N` w **foregroundzie**, albo `nohup … &` + odczyt wyniku **w tym samym wywołaniu** | zero powiadomień, wynik natychmiast |
| Bounded, długi (build, testy, deploy) | `background=true` + `notify_on_complete=true` | jedno powiadomienie na końcu, nie seria |
| Długożyjący (serwer, watcher, kolektor) | `background=true`, bez notify | nie umiera → nie ma o czym powiadamiać |

**Nie zostawiaj sprzątania na później.** Instancję testową dobijaj
w TYM SAMYM wywołaniu, w którym ją stwarzasz. Wzorzec „uruchom przez
`background=true`, potem w osobnej turze `pkill`" produkuje dokładnie tę lawinę
spóźnionych echos, na którą Suweren reagował: sześć meldunków o kodzie `-9`,
z których każdy dotyczył procesu dawno ubitego przez samego agenta.

**Gdy powiadomienie i tak dotrze spóźnione:** nie raportuj go osobno jako zdarzenia.
Potwierdź w jednej linii, że to echo sprzątania, i sprawdź zbiorczo stan
(procesy / porty / kontenery) JEDNYM wywołaniem. Nie odtwarzaj narracji.

## Checklista

- [ ] Źródło pobrane → zapisane do repo (`docs/design/<temat>-raw/`) ZANIM powstała synteza
- [ ] Krótkie procesy w foregroundzie / w tym samym wywołaniu — nie `background` + późny `pkill`
- [ ] Synteza ma odsyłacz do archiwum źródłowego
- [ ] Publiczne pliki mają kanoniczne uprawnienia; sekrety i prywatne backupy nie są upubliczniane przez chmod/chown ani commit
- [ ] Bramka `artifact-home.sh` uruchomiona przed jakimkolwiek `rm` w `/tmp`
- [ ] Artefakty subagentów przeniesione z `/tmp`, nie tylko zsyntetyzowane
- [ ] Zero odsyłaczy `/tmp/...` w dokumentach repo
- [ ] Cudze artefakty ZGŁOSZONE (rozmiar + wiek), nie usunięte

## Powiązania

- `references/mesh-trust-audit-four-sources.md` — **metoda czterech źródeł** przy badaniu
  rozproszonego systemu: gdy rejestry mówią różne rzeczy, rozbieżność JEST znaleziskiem.
  Zawiera pełny łańcuch root-cause „presence pusty → MCP `[]` → fałszywy wynik",
  rozjazd warstw transport/aplikacja, rozjazd nazewnictwa między rejestrami, oraz
  praktykę raportowania (baseline przed badaniem, korekty zapisane przeciw sobie).
- `references/jev-typesafe-systemone-api.md` — kontrakt API dostawcy zewnętrznego
- `agent-knowledge-transport` (kategoria `ops/`) — szersza kaskada nośników wiedzy;
  ta lekcja to jej konkretny przypadek: `/tmp` jako nośnik NIE istnieje
- `false-green-elimination` — ta sama rodzina: metryka dostępności ≠ wartość
- Reguła repo: „w raporcie podawaj przeczytane ścieżki" (AGENTS.md)

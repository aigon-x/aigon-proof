---
name: module-graph-wiring-gate
description: >-
  Wykrywaj i bramkuj „sieroty wpięcia" — pliki/moduły/zestawy/bramki, które
  ISTNIEJĄ i przechodzą na zielono, ale NIC ich nie woła (brak require/importu
  z produkcji, brak wywołania w buildzie, brak warstwy potoku). Daje: graf
  importów liczony od bootstrapów, tabelę jawnych WYJĄTKÓW z powodem, dowód
  negatywny detektora oraz inwentarz bramek PER WARSTWA dostawy (build →
  release → CI → pre-push → weryfikacja dostawy). Użyj, gdy pytanie brzmi
  „czy na pewno 100% bramek jest podpięte", „w każdej warstwie i każdym
  etapie", „to jest w ogóle wołane?", „dlaczego moduł istnieje, a nic nie robi",
  albo gdy dodajesz nowy plik/zestaw i chcesz, by bramka sama pilnowała wpięcia.
version: 1.0.0
author: AIGON-X (agent)
license: MIT
metadata:
  hermes:
    tags: [wiring, gates, coverage, orphan-detection, require-graph, ci, pre-push, audit]
    related_skills:
      - unwired-component-remediation
      - gate-layer-audit
      - verification-gate-hygiene
      - false-green-elimination
---


# Sieroty wpięcia: moduły i bramki, które istnieją, ale nikt ich nie woła

## Po co

Najdroższy fałszywy zielony nie brzmi „wywaliło się". Brzmi **„build jest
zielony"**. Plik leży w drzewie, ma test, test przechodzi — a z produkcji nikt
go nie `require`uje, więc jego praca nigdy nie dociera do użytkownika. Ten sam
defekt na poziomie procesu: zestaw testów jest na dysku, ale nie ma go w
bramce; bramka jest w bramce, ale nie ma jej w warstwie przed `git push`.

Zmierzone 2026-10-18 (gra Roblox `miki`): 68 modułów, **54 osiągalne**, 14 sierot
— w tym gotowy, przetestowany moduł kinowego intra (`Cinematic.lua`, 179 linii),
którego nikt nie wołał, oraz drugie lobby (`MenuScreen.luau`) z placeholderem.
`check_wiring.py` („czy plik jest w drzewie Rojo") przepuszczał je na zielono,
bo pilnował OBECNOŚCI, nie WYWOŁANIA.

## Zasada: OBECNOŚĆ ≠ WPIĘCIE

| pytanie | mierzy | wystarcza? |
|---|---|---|
| czy plik jest w drzewie/buildzie? | manifest, `check_wiring` | **NIE** |
| czy ktoś go `require`uje z korzenia produkcji? | graf importów od bootstrapów | TAK (dla modułów) |
| czy jest faktycznie WYWOŁANY (nie tylko require'owany)? | wywołanie w pętli/ticku | TAK (drugi bit) |
| czy zestaw testów jest w bramce? | tekst bramki + osiągalność | TAK |
| czy bramka jest w każdej warstwie dostawy? | inwentarz warstw | TAK |

## KROK 1 — graf importów od BOOTSTRAPÓW (nie „po całym repo")

1. Zbierz pliki źródłowe (`ls`, glob — nie `find` po `/`).
2. Dla każdego pliku wyciągnij **cele importów**.
3. BFS od realnych punktów wejścia produkcji (`bootstrap.server.*`,
   `bootstrap.client.*`, `main`, `index`).
4. Osiągalne = w zbiorze BFS. Reszta = **kandydaci na sieroty**.

### PITFALL detektora: zagnieżdżone nawiasy (zmierzone)

`require(script.Parent:WaitForChild("client"):WaitForChild("ClientController"))`
— naiwne `require\((.*?)\)` ucina się na **pierwszym** `)` i zwraca `"client"`
zamiast `ClientController`. Skutek: **cały klient raportowany jako sierota**
(25 „sierot" zamiast 15), a wniosek „klient nie działa" jest fałszywy.

Poprawnie: licząc importy, bierz **ostatni** identyfikator z linii — z cudzysłowów
(`"X"`) i z kropki (`.X`), pomijając `Parent`/`WaitForChild`:

```python
for line in code.splitlines():
    if "require(" not in line:      # po usunięciu komentarzy!
        continue
    ids = re.findall(r'"([A-Za-z_]\w*)"|\.([A-Za-z_]\w*)', line)
    flat = [a or b for a, b in ids if (a or b) not in ("Parent", "WaitForChild", "script")]
    if flat: deps.add(flat[-1])
```

**Kompresuj komentarze PRZED analizą** — inaczej `-- require(Foo)` w komentarzu
tworzy krawędź, a „kod w komentarzu" daje fałszywy PASS (klasa zmierzona
w bramkach tego repo: komentarz udawał wywołanie).

## KROK 2 — WYJĄTKI Z POWODEM, nie ciche pominięcie

Sierota nie zawsze jest błędem: gałąź referencyjna, skrypt silnika (nie moduł),
moduł pomocniczy używany tylko przez inny (martwy) moduł. Reguła:

- każdy wyjątek ma **powód w kodzie testu** (≥ 10 znaków, konkretny — „bo tak" nie jest powodem),
- brak wpisu w tabeli = **FAIL** (ciche pominięcie jest zakazane),
- wyjątek jest DECYZJĄ do raportu, nie po cichu (zasada „niczego nie kasujemy —
  podpinamy albo jawnie klasyfikujemy").

```lua
local EXEMPT = {
  ["src/health.server.lua"] = "skrypt StarterCharacterScripts — silnik, nie moduł",
  ["src/server/Main.lua"]   = "gałąź referencyjna: logika żyje w ServerRuntime",
  ["src/client/MenuScreen.luau"] = "martwy duplikat lobby — DECYZJA właściciela",
}
```

## KROK 3 — DOWÓD NEGATYWNY (bez tego bramka nie istnieje)

Zbuduj **sztuczny graf** z jedną sierotą i sprawdź, że detektor ją widzi;
potem graf domknięty i sprawdź, że jest zielony:

```lua
local fake = { root = "local a = require(script.Child)", Child = "return {}", Orphan = "return {}" }
-- reach(Orphan) == nil  → detektor widzi lukę
```

Ta sama zasada co przy każdej bramce: **sabotaż → CZERWONY, przywrócenie → ZIELONY**.

## KROK 4 — inwentarz bramek PER WARSTWA

Pytanie „czy 100% bramek jest podpięte" ma odpowiedź tylko jako macierz
`bramka × warstwa`. Warstwy do sprawdzenia (każda osobno, każda może być pusta):

| warstwa | plik/mechanizm | co ma tam być |
|---|---|---|
| build | `scripts/build.sh` | lint + wszystkie zestawy + powtarzalność |
| release | `scripts/release.sh` | build + paczka + dowód + testy negatywne |
| deploy | `scripts/ci-local.sh` / runner | weryfikacja po wdrożeniu (receipt) |
| CI | `.github/workflows/*.yml` | woła **tę samą** bramkę, nie kopię kroków |
| pre-push | `.git/hooks/pre-push` | SZYBKIE bramki klas defektów |
| dostawa | `verify-delivery.py` | pobranie publiczne + SHA + health |

Wzorzec wykrywania: dla każdej bramki sprawdź, czy jej **basename** występuje
w tekście każdej warstwy; wypisz sieroty per warstwa. Gotowy skrypt:
`scripts/gate_layer_inventory.py` (parametryzowany korzeniem i listą warstw).

### Zmierzona luka: brak warstwy pre-push

Pełna bramka w CI i w release, a **nic** między `commit` a `push` → commit
z sierotą jechał do repo i czerwienił się u następnego, kto uruchomił build.
Domknięcie: hook instalowany z repo (`scripts/install-git-hooks.sh`), który
uruchamia **tylko szybkie** bramki klas defektów (lint + graf wpięcia + pokrycie
zestawów, < 10 s). Pełna bramka zostaje tam, gdzie jej miejsce — hook ma łapać
KLASĘ, nie udawać release'u.

## KROK 5 — wpięcie RUNTIME, nie tylko importowe

Import się zgadza, a wyjście nie dociera do użytkownika — ta sama klasa, inna
warstwa. Trzy zmierzone warianty (szczegóły: `references/presentation-reaches-user.md`):

1. **Dźwięk 2D z serwera = cisza.** `SoundService` NIE jest replikowany; `Sound`
   utworzony na serwerze pod `SoundService` nie istnieje u klienta. Serwer ma
   wysyłać INTENCJĘ (remote), klient odtwarza lokalnie (także 3D — sam stawia
   emiter). Objaw: klucze w Config poprawne, `AssetId` publiczne (HTTP 302),
   a gracz słyszy nic.
2. **Efekt wysłany, brak gałęzi w kliencie.** Serwer `effect{kind="magic"}`,
   klient nie zna kindu → czar „nie poszedł”. Bramka: każdy kind serwera ma
   konsumenta albo jawny wyjątek.
3. **Rig/NPC bez `Humanoid` = brak animacji.** Cykl nóg liczony z
   `Humanoid.RootPart.AssemblyLinearVelocity` nie zadziała dla modelu z samym
   `Motor6D`; podaj prędkość z delty pozycji (`studsOverride`) i skanuj modele
   raz na sekundę, nie co klatkę.

Reguła ogólna: **wyjście musi mieć konsumenta w procesie, który je produkuje**
(klient rysuje/gra to, co serwer wysyła; serwer nie tworzy instancji, których
nie replikuje). Import-graf tego NIE złapie — potrzebny strażnik pokrycia
kindów/ścieżek prezentacji.

## PITFALLS (wszystkie zmierzone)

1. **`#tabela` w Lua na mapie (hash) = 0.** Liczenie „osiągalnych" przez
   `#seen` daje 0 przy niepustym zbiorze → bramka „widzi" pustkę. Licz
   pętlą `for _ in pairs(t)`.
2. **Nowy zestaw testów musi wejść do `build.sh`** — inaczej bramka pokrycia
   (np. `check_gate_coverage.py`) słusznie czerwieni: „zestaw na dysku, brak
   wywołania".
3. **Nowa zależność klienta wymaga wpisu w atrapach testowych.** Brak modułu
   w whitelistcie harnessu = `unmodelled module X` i zestaw mierzy brak atrapy,
   nie zachowanie. To samo dla klas instancji (`unmodelled class: ViewportFrame`)
   i globali (`Vector3`, `CFrame`, `NumberSequence`) — dopisz stuby, nie
   „naprawiaj" test.
4. **Liczby w dokumentacji bywają bramkowane do kodu.** Dodanie jednego wpisu
   w Config (np. 25 → 26 dźwięków) wywala bramki `docs` — aktualizuj dokument
   w TYM SAMYM commicie; to nie jest „drobiazg", to część zmiany.
5. **`grep` po nazwie pola łapie komentarze i telemetrię.** Kindy efektów
   zbieraj tylko z realnych wywołań; importy — po usunięciu komentarzy.
6. **Zielony build nie jest dowodem wpięcia.** Dowodem jest albo wpis w grafie
   od bootstrapu, albo uruchomienie zmienionej ścieżki (zrzut/telemetria).
7. **Nie usuwaj sieroty, gdy nie znasz zamiaru.** Klasyfikuj: wpiąć / wyjątek
   z powodem / decyzja właściciela. Usunięcie „martwego" modułu bywa usunięciem
   gotowej funkcji, której nikt nie zdążył podpiąć.
8. **TWARDA REKA ROZSZERZENIA W DETEKTORZE = niewidoczne pliki (zmierzone).**
   `find src -name '*.lua'` w strażniku palety NIE widział `*.luau`, a taki plik
   jedzie do builda razem z resztą: `MenuScreen.luau` wiózł **6 surowych
   `Color3.fromRGB`** i przechodził na zielono, mimo asercji „KAŻDY plik src".
   Reguła: enumeracja źródeł MUSI obejmować wszystkie rozszerzenia, które
   trafiają do artefaktu (`\\( -name '*.lua' -o -name '*.luau' \\)`), a bramka
   ma mieć asercję „plik X jest w zasięgu skanu" — bez niej luka wraca cicho
   przy pierwszym nowym rozszerzeniu. Ten sam wzorzec sprawdź w KAŻDYM
   detektorze, który listuje pliki po nazwie/globie.
9. **Edytowanie źródeł W TRAKCIE przebiegu bramki = fałszywy FAIL
   powtarzalności (zmierzone).** `build.sh` robi dwa buildy (artefakt + kontrola
   repro) i porównuje hashe; zmiana pliku między nimi daje „build nie jest
   powtarzalny" — alarm o NIEDETERMINIZMIE, którego przyczyną jest Twoja własna
   edycja. Reguła: gdy leci pełna bramka/release, **zamroź `src/`** (czekaj),
   poprawiaj po zakończeniu; jeśli FAIL repro pojawi się mimo zamrożonego
   drzewa, DOPIERO WTEDY szukaj niedeterminizmu w buildzie.

## CHECKLIST

- [ ] graf importów liczony od bootstrapów produkcji (nie „po repo")
- [ ] komentarze usunięte PRZED analizą
- [ ] importy z zagnieżdżonymi nawiasami rozwiązane (ostatni identyfikator)
- [ ] każda sierota: wpięta ALBO w tabeli wyjątków z powodem
- [ ] dowód negatywny: sztuczna sierota → FAIL, domknięty graf → PASS
- [ ] nowy zestaw dopisany do `build.sh`
- [ ] macierz `bramka × warstwa` (build/release/deploy/CI/pre-push/dostawa)
- [ ] brakująca warstwa domknięta lekkim hookiem, nie kopią pełnej bramki
- [ ] raport: liczby (`osiągalne/total`, `sieroty`, `wyjątki`) + decyzje do właściciela

## Materiały

- `references/presentation-reaches-user.md` — wyjście, które nie dociera do
  gracza: dźwięk 2D przez `SoundService` (nie replikowany), kindy efektów bez
  gałęzi w kliencie, NPC bez `Humanoid` (animacja z delty pozycji) + strażnicy.
- `references/luau-require-graph-gate.md` — gotowy zestaw `tests/wiring_coverage.lua`
  (graf z bootstrapów, tabela wyjątków, dowód negatywny) oraz lista stubów
  harnessu potrzebnych, gdy klient zyskuje nowe klasy Instancji.
- `scripts/gate_layer_inventory.py` — inwentarz: które bramki/zestawy woła
  która warstwa dostawy; wypisuje sieroty per warstwa.

# Trwały profil gracza: strażnik ROUND-TRIP CAŁEGO KATALOGU (zmierzone 2026-10-13)

Klasa: **kupione/zdobyte przedmioty gracza znikają przy wczytaniu profilu**, a
żaden test tego nie widzi. Dwa niezależne defekty tej samej rodziny, oba
zmierzone w produkcyjnym Luau (Roblox, projekt miki), oba ciche: zero błędów w
logu, gracz płaci i traci. Warto je znać razem, bo występują parami.

## Defekt A — normalizator z HARDKODOWANĄ białą listą

```lua
-- ŹLE: normalizator przepuszcza dwa klucze wpisane na sztywno
function Rules.profile(raw)
  local unlocks = type(raw.unlocks) == "table" and raw.unlocks or {}
  return {
    coins = ...,
    unlocks = { shotgun_basic = unlocks.shotgun_basic == true,
                rifle_basic   = unlocks.rifle_basic   == true },   -- ← reszta KASOWANA
  }
end
```

Skutek: każda broń kupiona za monety (bazooka 520, nailstorm, flamer, rail) albo
wypadnięta z łupu bossa **ginęła przy wczytaniu profilu** — bo wczytanie
przechodzi przez ten normalizator. Gracz zapłacił i nie ma.

```lua
-- DOBRZE: zachowaj KAŻDE sensowne odblokowanie, ale z twardym oczyszczeniem
local MAX = 64
local clean, n = {}, 0
for id, v in pairs(unlocks) do
  if type(id) == "string" and #id >= 1 and #id <= 40 and v == true and n < MAX then
    clean[id] = true; n = n + 1
  end
end
```

Reguła: **normalizator nie jest miejscem na listę „znanych" identyfikatorów.**
Biała lista jest z definicji niepełna wobec katalogu (Config.Weapons / dodatków)
i starzeje się z każdą nową pozycją. Jeśli naprawdę chcesz ograniczyć zbiór —
buduj go z KATALOGU, nie z literałów.

## Defekt B — zapis porównuje WYBRANE pola, nie CAŁY rekord

```lua
-- ŹLE: „dirty check" wyliczony z ręcznej listy dwóch pól
local unchanged = current.coins == snapshot.coins
  and current.best == snapshot.best
  and current.unlocks.shotgun_basic == snapshot.unlocks.shotgun_basic
  and current.unlocks.rifle_basic   == snapshot.unlocks.rifle_basic
```

Odblokowanie z łupu bossa (bez zmiany monet) **nie zaznaczało profilu jako
zmienionego** → zapis pomijany → nagroda przepada po sesji. Ta sama pułapka
dotyczy każdego „dirty check" składanego z ręcznej listy pól.

```lua
-- DOBRZE: jedna funkcja porównująca ZBIÓR (czysta, testowalna bez silnika)
function Rules.unlocksEqual(a, b)
  local ca, cb = 0, 0
  for id, v in pairs(type(a) == "table" and a or {}) do
    if v == true then
      ca = ca + 1
      if (type(b) == "table" and b[id]) ~= true then return false end
    end
  end
  for _, v in pairs(type(b) == "table" and b or {}) do
    if v == true then cb = cb + 1 end
  end
  return ca == cb
end
```

## Strażnik: ROUND-TRIP CAŁEGO KATALOGU (kwintesencja tego pliku)

Nie „czy pole istnieje" — **czy każda pozycja katalogu przechodzi przez
normalizator bez straty**:

```lua
local wide = {}
for id in pairs(Config.Weapons) do wide[id] = true end          -- źródło: KATALOG
local norm = Rules.profile({ coins = 10, best = 1, unlocks = wide })
local lost = {}
for id in pairs(wide) do
  if norm.unlocks[id] ~= true then lost[#lost + 1] = id end
end
check("każda broń z katalogu przeżywa normalizację ("..#lost.." zgubionych)", #lost == 0)
```

Do tego trzy asercje, które zamykają resztę klasy:

1. **Śmieci odpadają**: `false`, liczba, klucz liczbowy, klucz pusty, klucz > 40
   znaków → `nil` na wyjściu.
2. **Limit działa**: 200 wpisów na wejściu → ≤ 64 na wyjściu (dane gracza nie
   rozdymają profilu).
3. **Porównywarka widzi zmianę w KAŻDYM elemencie**: dodany / usunięty /
   podmieniony klucz → `false`; identyczne zbiory → `true`; `nil`/`{}` nie wywala.

Wpięcie: jeden zestaw na klasę (`tests/unlocks_persistence.lua`) w bramce
projektu. Wzorzec działa dla każdego katalogu gracza — bronie, skórki,
osiągnięcia, odznaki, poziomy — wszędzie, gdzie jest „lista pozycji × trwały
profil".

## Dowód offline bez uruchamiania gry (moduły czyste)

Gdy moduły są czyste (bez `Instance`/`workspace`/`require(script...)`), odtwórz
pełny obieg produkcyjny `dofile`-em — bez Studia, bez serwera:

```lua
local C = dofile("src/shared/config/Config.lua")
local R = dofile("src/server/GameRules.lua")
local loaded = R.profile({ coins = 80, unlocks = { bazooka = true } })   -- WCZYTANIE
local inv = R.inventory(C, loaded, "bazooka", "miki")                    -- DROGA GRACZA
print(inv.active, inv.guns.bazooka ~= nil)   -- oczekiwane: bazooka true
```

**Uwaga na realizm wejścia (zmierzony fałszywy czerwony):** pierwsza wersja
dowodu wołała `inventory(..., nil)` (bez bohatera) i pokazała „nie da się
wybrać" — a produkcja ZAWSZE ma wybranego bohatera (`active` ustawiane tylko gdy
`hero ~= nil`). Dowód musi odtwarzać ścieżkę PRODUKCYJNĄ, nie dowolną wygodną —
to ta sama rodzina co „mierzysz nie tę rolę" z SKILL.md.

## Sygnatury rozpoznawcze (kiedy szukać tej klasy)

- w kodzie wczytywania widać **ręcznie wypisane klucze** (`x = unlocks.x`),
- „dirty check" / „needsSave" składa się z `and`-ów po konkretnych polach,
- test mówi „pole istnieje / normalizator zwraca tabelę", a nie „pozycja
  przechodzi round-trip",
- objaw od gracza brzmi: „kupiłem i nie mam" / „wypadło mi z ekwipunku" bez
  żadnego błędu w logu.

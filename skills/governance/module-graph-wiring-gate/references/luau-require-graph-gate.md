# Bramka „sieroty wpięcia" w Luau/Roblox (gotowy wzorzec)

Źródło: `tests/wiring_coverage.lua` w projekcie Roblox/Luau (Rojo), 2026-10-18.
Uruchamiana w `scripts/build.sh` **po** `check_wiring.py` (który pilnuje tylko
obecności pliku w drzewie).

## Kontrakt

1. Policz graf `require()` od `src/bootstrap.server.lua` i `src/bootstrap.client.lua`.
2. Każdy moduł musi być osiągalny **albo** mieć wpis w `EXEMPT` z powodem.
3. Brak wpisu = FAIL. Pusty/„bo tak" powód = FAIL.
4. Dowód negatywny: sztuczny graf z sierotą → detektor musi ją zobaczyć.

## Szkielet (lua5.1, bez Roblox API)

```lua
local stripSrc = dofile("tests/strip.lua")   -- usuwa komentarze linowe i blokowe

local function fileText(path)
  local f = assert(io.open(path, "r"), "brak pliku " .. path)
  local d = f:read("*a"); f:close()
  return stripSrc(d)                          -- KLUCZ: komentarze PRZED analizą
end

local paths, isPath = {}, {}
local pipe = io.popen("ls src/bootstrap.*.lua src/server/*.lua src/server/skills/*.lua "
  .. "src/shared/*.lua src/shared/config/*.lua src/client/*.lua src/client/*.luau src/*.server.lua 2>/dev/null")
for line in pipe:lines() do
  if not isPath[line] then paths[#paths + 1] = line; isPath[line] = true end
end
pipe:close()

-- Zależności: OSTATNI identyfikator w linii z require( — obsługa
-- require(script.Parent:WaitForChild("X")) (zagnieżdżone nawiasy).
local deps = {}
for _, path in ipairs(paths) do
  local set = {}
  for line in fileText(path):gmatch("[^\n]+") do
    if line:find("require(", 1, true) then
      local last = nil
      for name in line:gmatch('"([%w_]+)"') do last = name end
      for name in line:gmatch("%.([%a_][%w_]*)") do
        if name ~= "Parent" and name ~= "WaitForChild" then last = name end
      end
      if last then set[last] = true end
    end
  end
  deps[path] = set
end

local function stem(p) return p:match("([^/]+)%.lua$") or p:match("([^/]+)%.luau$") or p end
local byStem = {}
for _, p in ipairs(paths) do
  local s = stem(p); byStem[s] = byStem[s] or {}; table.insert(byStem[s], p)
end

local seen, queue = {}, { "src/bootstrap.server.lua", "src/bootstrap.client.lua" }
while #queue > 0 do
  local cur = table.remove(queue)
  if not seen[cur] then
    seen[cur] = true
    for name in pairs(deps[cur] or {}) do
      for _, target in ipairs(byStem[name] or {}) do
        if not seen[target] then table.insert(queue, target) end
      end
    end
  end
end
```

## Liczenie „osiągalnych" — PUŁAPKA Lua

```lua
-- ŹLE: #seen na mapie (hash) = 0 → bramka „widzi" pustkę
-- DOBRZE:
local seenCount = 0
for _ in pairs(seen) do seenCount = seenCount + 1 end
```

## Tabela wyjątków (przykład realny)

```lua
local EXEMPT = {
  ["src/health.server.lua"]        = "skrypt StarterCharacterScripts — uruchamia silnik, nie moduł",
  ["src/server/Main.lua"]          = "gałąź referencyjna (CLAUDE.md): logika żyje w ServerRuntime",
  ["src/server/Combat.lua"]        = "gałąź referencyjna: decyzja trafień w Weapons",
  ["src/client/MenuScreen.luau"]   = "MARTWY duplikat lobby — decyzja właściciela",
  ["src/server/Vehicles.lua"]      = "funkcja niezapięta w runtime — decyzja właściciela",
  ["src/shared/UiZones.lua"]       = "moduł pomocniczy — konsument tylko MenuScreen (martwy)",
}
```

## Dowód negatywny

```lua
local fake = { root = 'local a = require(script.Child)', Child = 'return {}', Orphan = 'return {}' }
local reach = graphOf(fake, { "root" })
-- PASS: reach["Child"] == true and reach["Orphan"] == nil
```

## Harness klienta: co dopisać, gdy moduł/klasa są nowe

Objawy i poprawki (wszystkie zmierzone):

| objaw | przyczyna | poprawka w atrapie testowej |
|---|---|---|
| `unmodelled module Cinematic` | klient wymaga nowego modułu | dopisz `dofile("src/shared/<X>.lua")` do listy modułów harnessu |
| `unmodelled class: ViewportFrame` | nowa klasa Instancji | dopisz klasę + jej WŁAŚCIWOŚCI do whitelisty |
| `attempt to index global 'Vector3'` | nowe globalne API | stub `Vector3.new`, `CFrame.new/Angles/lookAt` (z `__mul`), `Color3.new` |
| `NumberSequence is nil` | nowe typy sekwencji | stub `NumberSequence`, `NumberSequenceKeypoint`, `NumberRange`, `TweenInfo` |
| test mierzy „brak atrapy" | atrapa nie modeluje API, którego klient realnie woła | modeluj metody (`FindFirstChildOfClass`, `WaitForChild`), nie pusty `{}` |

Zasada: atrapa ma modelować **kontrakt**, nie render. Dowodem wyglądu jest
zrzut z urządzenia, nie test offline.

## Wpięcie w bramkę

```bash
echo "==> wiring (src <-> *.project.json)"
python3 tests/check_wiring.py
echo "PASS: wiring"

# WIRING-COVERAGE: check_wiring pilnuje OBECNOŚCI pliku, nie WYWOŁANIA.
lua5.1 tests/wiring_coverage.lua
```

# Callback podłączony, zła sygnatura — pełny zapis (miki, 2026-10-13)

Audyt EKONOMII I PROGRESJI (read-only) w grze Roblox/Luau `miki`. Pytanie:
czy każda odznaka z `Config.Badges` (9) realnie dochodzi do portfela gracza.

## Droga wypłaty (docelowa)

`zdarzenie rundy → Progression:note()` (Progression.lua:469, zwraca listę przyznanych)
`→ payAwarded()` (ServerRuntime.lua:170-184) → `Rules.payBadges()`
(GameRules.lua:188) → `Rules.grantCoins()` → `profile.coins`.

## Wynik per odznaka

| Odznaka | Monety | Emisja zdarzenia w src/ | Wypłata |
|---|---|---|---|
| first_blood | 5 | Weapons.lua:136 | ❌ NIE (zła sygnatura onBadge) |
| sharpshooter | 15 | Weapons.lua:136 | ❌ NIE (zła sygnatura onBadge) |
| untouched | 25 | ServerRuntime.lua:1428 | ✅ |
| collector | 20 | ServerRuntime.lua:428 | ✅ |
| night_shift | 40 | ServerRuntime.lua:1428 | ✅ |
| caretaker | 20 | **BRAK** (tylko komentarz 2412) | ❌ NIGDY przyznawana |
| last_stand | 30 | ServerRuntime.lua:1591 | ✅ |
| looter_drop | 25 | ServerRuntime.lua:430 | ✅ |
| medic | 10 | Revive.lua:179 → ServerRuntime.lua:1331 | ✅ (drogą awardBadge) |

Suma zadeklarowana 190 monet/rundę → realnie maks. 150/rundę.

## Defekt #1 — zła sygnatura `onBadge`

`Weapons.new(director, players, effect, progression, powers, onBadge)`
(Weapons.lua:51) ma kontrakt `onBadge(userId, awarded)` (Weapons.lua:46-50).
`Weapons` woła `self.onBadge(recipient.player.UserId, awarded)`
(Weapons.lua:141-142), gdzie `awarded` to LISTA odznak z `:note()`.

Ale ServerRuntime przekazuje jako 6. argument `progressionNote` (ServerRuntime.lua:414),
które ma sygnaturę `progressionNote(userId, event, data)` (ServerRuntime.lua:185).
Skutek: lista odznak trafia w slot `event` → `note()` nie dopasowuje `if event == "..."``
→ zwraca `{}` → `payAwarded` nie płaci.

**Dlaczego zielono:** `tests/badges.lua:107-108` asertuje właśnie
`rsrc:find("Weapons%.new%([^)]*progressionNote%s*%)")` — czyli test UTRWALA błędne
okablowanie. Naprawa musi objąć też test (asercja behawioralna, nie string).

## Defekt #2 — „brak emisji", nie „zła sygnatura"

`core_repair` istnieje w `Progression:note` (Progression.lua:513-517, odznaka
`caretaker`), ale w produkcji to tylko KOMENTARZ (ServerRuntime.lua:2407-2414:
`-- progression:note(..., "core_repair")`, obok „mechaniki jeszcze NIE MA").
`tests/badges.lua:196-199` ma jawną allowlistę znanych luk
(`allowedKnownGaps = { caretaker = true }`) → defekt udokumentowany, ale nadal PASS.

## Dowód empiryczny (moduły czyste, lua5.1, bez Robloxa)

```lua
local base = "src/"
local Config      = dofile(base .. "shared/config/Config.lua")
local Progression = dofile(base .. "server/Progression.lua")
local Rules       = dofile(base .. "server/GameRules.lua")
local players = { [42] = { userId=42, player={}, profile={coins=0,granted={}},
                           active=true, alive=true, role="player" } }
local prog = Progression.new(players, Config, nil)
-- KROK 1 (Weapons.lua:136): award
local awarded = prog:note(42, "kill", { distanceStuds = 150 })
-- KROK 2 (Weapons.lua:142): onBadge=progressionNote
local function progressionNote(u, ev, d) local a = prog:note(u, ev, d)
  if #a > 0 then Rules.payBadges(Config, players[u].profile, a, 1) end end
progressionNote(42, awarded)                       -- tak woła produkcja
print(players[42].profile.coins)                   -- 0  ← DOWÓD
-- Kontr-test: gdyby onBadge było payAwarded wprost → 20 (first_blood 5 + sharpshooter 15)
```

Wynik: `0` na drodze produkcyjnej vs `20` na poprawnej. Bez uruchamiania gry.

## Minimalna naprawa (bez zmian w tym audycie)

ServerRuntime.lua:414 — przekazać `payAwarded` zamiast `progressionNote` jako 6. arg
`Weapons.new`; dodać test behawioralny wypłaty przez `onBadge` (saldo portfela),
bo obecny sprawdza tylko obecność stringa.

## Kontekst balansu (przy okazji audytu)

- `Config.Levels.Xp = { Kill=12, Chest=25, Night=120, CoreRepair=30, Revive=30, Duel=60 }`.
  `CoreRepair` nigdy nieużywane (komentarz ServerRuntime.lua:2413). `Duel` wpięte
  2026-10-13 (ServerRuntime.lua:936, reachable przez `rewardWinner`).
- Sklep (6 pozycji) — wszystkie kupowalne (`Rules.buy`, GameRules.lua:65); ceny
  osiągalne (start 0, ~150+ monet/rundę).
- Suma progów do L30 = 45259 XP (BaseXp=120, wzrost 15%). Runda ≈ 610 s
  (DAY300+WARN60+NIGHT240+DAWN10) + RESULTS ≥20 s. ~41-74 rundy ≈ 7-13 h gry.

# Wyjście, które nie dociera do gracza (wpięcie RUNTIME)

Uzupełnienie statycznego grafu importów: trzy klasy defektów, w których kod JEST
wołany, a efekt nigdy nie dociera do odbiorcy. Wszystkie zmierzone 2026-10-18
w grze Roblox (`miki` / „Przebudzenie Korzeni”), po audycie, w którym gracz
zaraportował: „nie ma grafik, nie ma animacji, nie ma dźwięków”.

## 1. Dźwięk 2D z serwera = CISZA (`SoundService` nie jest replikowany)

**Pomiar:** `Audio.play`/`Audio.music` wołane z serwera w 11 miejscach
(`Weapons.lua`, `ServerRuntime.lua`, `Loot.lua`, `Revive.lua`). Klucze w Config
poprawne, `AssetId` publiczne (`assetdelivery` → 302 dla 5/6 sprawdzonych; 403
tylko dla własnego narration, co jest normalne). A 17 z 25 dźwięków i CAŁA
muzyka były ciszą.

**Przyczyna:** `Sound` utworzony na serwerze pod `SoundService` nie istnieje
w drzewie klienta — SoundService nie jest replikowany. (Sound w `Workspace`
replikuje się inaczej — dlatego 3D „czasem działa”, co maskuje defekt.)

**Naprawa (jeden moduł, jeden wykonawca):**

```lua
-- Net.REMOTES.Audio = "audio"  (bootstrap tworzy remote z listy REMOTES)
local isServer, hasGame = false, false
pcall(function() hasGame = game ~= nil; isServer = game:GetService("RunService"):IsServer() end)

function Audio.play(name, position)
  if type(name) ~= "string" or name == "" then return false, "invalid_name" end
  if isServer then
    local ev = audioRemote()          -- ReplicatedStorage.Net.audio
    if ev then
      pcall(function() ev:FireAllClients({ kind = "play", name = name, position = position }) end)
      return true, "replicated"
    end
    -- brak remote (offline/harness) → zachowanie lokalne, testy zostają zielone
  end
  return playLocal(name, position)    -- ta sama funkcja, to samo throttle
end
```

Klient: `ev.OnClientEvent` → `pcall(playLocal, msg.name, msg.position)`.
Nie cache'uj PORAŻKI szukania remote'u (folder `Net` powstaje w bootstrapie —
pierwsze wołanie może wypaść przed nim); cache'uj tylko sukces.

**Strażnik dwustronny** (`tests/audio_route.lua`, 14 asercji):
(A) remote istnieje i jest używany przez `play` **i** `music`;
(B) każde `Audio.play("x")` i `uiSfx("x")` ma klucz w Config;
(C) każdy klucz Config ma konsumenta (martwy dźwięk = zapłacony asset bez użycia);
(D) sabotaż trasy (usunięcie `replicate("play")`, podmiana `IsServer`) → CZERWONY.

**Pułapka detektora:** `uiSfx("x")` to DRUGI choke point dźwięków UI — pominięcie
go daje fałszywy alarm „martwe ui_click/ui_select”. Miernik, nie defekt.

## 2. Efekt wysłany, brak gałęzi w kliencie

Serwer wysyła `effect({kind = "magic", ...})`, klient nie ma `elseif` na ten
kind → gracz nie widzi, że czar poszedł. Bramka: zbiór kindów z **wywołań
`effect(...)`** (nie z telemetrii!) musi być podzbiorem kindów obsługiwanych
w kliencie, a każdy wyjątek ma powód w teście.

Detektor: `effect%(.-kind = "([a-z_]+)"` (w Lua `.` łapie nową linię — wywołania
wielolinijkowe!). `grep 'kind = "x"'` po całym `src/server/` łapie pola
telemetrii i daje fałszywe „efekt bez konsumenta”.

## 3. Rig/NPC bez `Humanoid` — animacja nie ma z czego liczyć prędkości

`hud:locomotion(model)` czytało `Humanoid.RootPart.AssemblyLinearVelocity`, a
zombie/boss/elita to modele z samym rigiem `Motor6D` (bez Humanoid) → prędkość 0
→ nogi nie drgają, mimo że gracze chodzą normalnie.

Naprawa:
- `view:locomotion(model, studsOverride)` — opcjonalna prędkość z zewnątrz,
- klient skanuje modele z `Motor_Torso` **raz na sekundę** (nie co klatkę),
  liczy `(pos - prev).Magnitude / dt` i podaje jako `studsOverride`,
- wyklucza modele z `Humanoid` (żeby nie dublować graczy).

## Reguła ogólna

Każde wyjście prezentacji (dźwięk, efekt, animacja, UI) musi mieć **konsumenta
w tym samym procesie, który je produkuje**. Graf importów tego nie złapie —
potrzebne są strażniki pokrycia per kanał: kindy efektów, klucze dźwięków,
akcje animacji, elementy HUD.

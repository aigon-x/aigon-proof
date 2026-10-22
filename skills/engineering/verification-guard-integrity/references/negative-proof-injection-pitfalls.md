# Dowód negatywny: jak wstrzyknąć defekt tak, żeby NAPRAWDĘ trafił

Cel: udowodnić, że strażnik/bramka NIE jest false-green — wstrzykujemy defekt i
wymagamy FAIL. Klasa ryzyka: **samo wstrzyknięcie cicho no-opuje**, więc mierzysz
oryginał i wyciągasz błędny wniosek („bramka nic nie łapie" ALBO — gorzej —
zapisujesz fałszywy wynik).

## Pułapka 1 — wzorzec-kotwica (`gsub`/`replace`) zjada literał (zmierzone 2026-10-13)

W `lua5.1` `string.gsub(s, pat, repl)` traktuje `pat` jako WZORZEC: `(`, `)`, `.`,
`"`, `-`, `%`, `+`, `[`, `]` są MAGICZNE. Mutacja literału takiego jak
`Instance.new("Trail")` przez `gsub` **nie trafia** (wzorzec nie pasuje), string
wraca niezmieniony, a kontrola negatywna nadal przechodzi. Efekt uboczny:
fałszywy wniosek „guard nie łapie usunięcia Trail".

Zmierzone: `s:gsub('Instance.new("Trail")', 'X')` → string IDENTYCZNY. Ten sam
skrypt, poprawiona wersja → `false` (jak oczekiwano).

**Fix A — literalny find + splice (najbezpieczniejszy):**
```lua
local function remove(s, lit)
    local a, b = s:find(lit, 1, true)   -- true = PLAIN, zero magii
    if not a then return s end
    return s:sub(1, a - 1) .. s:sub(b + 1)
end
```
**Fix B — escape wzorca:** podwój `%` i poprzedź znaki magiczne `%`, potem `gsub`.

## Pułapka 2 — negatyw na wyciętym kawałku bez kotwicy => false-pass

`slice:find("rbxassetid", 1, true) == nil` przechodzi, gdy slice jest PUSTY (np.
kotwica cięcia nie znalazła się w pliku). Mierzysz „brak" na niczym.
**Fix:** złącz negatyw z kotwicą, o której WIESZ, że jest w zakresie:
```lua
check("...zero rbxassetid...",
    slice:find('fx.Shape == "arcs"', 1, true) ~= nil   -- kotwica: zakres niepusty
    and slice:find("rbxassetid", 1, true) == nil)
```

## Checklista (language-agnostic)

1. **Czy mutacja trafiła?** Po zbudowaniu zmutowanego wejścia: `assert(mutated ~= original)`.
   No-op mutacji i strażnik, który nie łapie, są NIEROZRÓŻNIALNE dopóki tego nie sprawdzisz.
2. **Czy zakres jest niepusty i zakotwiczony?** Negatyw na pustym cięciu = false-pass.
3. **Czy kontrola NAPRAWDĘ robi FAIL na zmutowanym wejściu?** To jest dowód, że bramka zęby ma.
4. **Cofnij bajt-w-bajt** (`sha256` przed == po), jeśli dotykałeś pliku repo. Preferuj
   mutację W PAMIĘCI (czytaj plik do zmiennej, mutuj string) nad edycją drzewa — zero ryzyka
   kolizji z równoległym pisarzem i zero szansy, że „przywrócenie" zostawi ślad.

## Jak to wygląda w praktyce (skrypt ad-hoc, nie edycja repo)
```lua
local h = readfile("src/client/Hud.lua")                 -- do zmiennej
local s = h:sub(h:find("function view:burst",1,true),
                h:find("function view:damageNumber",1,true)-1)
local mut = remove(s, 'Instance.new("Trail")')
assert(mut ~= s, "wstrzyknięcie no-op — sprawdź wzorzec") -- KROK 1
assert(guard(mut) == false, "strażnik NIE łapie defektu")  -- KROK 3
-- oryginał pliku nietknięty
```

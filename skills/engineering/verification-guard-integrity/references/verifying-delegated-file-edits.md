# Weryfikacja PLIKU po delegowanej edycji (zmierzone 2026-10-13, AIGON/construction)

Klasa: subagent (delegate_task) twierdzi "plik zepsuty / nie moge odbudowac"
albo "gotowe", a prawda jest inna. Nigdy nie ufaj self-reportowi — ani w strone
"zepsute", ani "dziala". Sprawdz DOWODEM.

## Krok 0 — inwentarz przed werdyktem
```
stat -c '%s B %y' <plik>            # rozmiar + mtime
ls -la /tmp/*<Nazwa>*.bak           # backup subagenta (hazard: subagent potrafi WYCZYSCIC plik)
git status --short -- <sciezka>     # kto jeszcze rusza ten obszar (kolizja pisarzy)
```

## Krok 1 — PRAWDZIWY parser, NIE liczenie nawiasow
Liczenie nawiasow (regex strip + stos) KŁAMIE na template-literalach `${...}`
i JSX — dawalo `leftover=1` na pliku, ktory byl OK, albo odwrotnie.
Uzyj parsera jezyka:
```bash
node -e "const fs=require('fs'),b=require('@babel/parser');
try{b.parse(fs.readFileSync('src/X.js','utf8'),{sourceType:'module',plugins:['jsx']});
console.log('PARSE OK')}catch(e){console.log('ERR',e.message,'| linia',e.loc&&e.loc.line)}"
```
Wynik daje KLASE bledu i linie/kolumne (np. `Identifier 'agg' has already been
declared. (158:12)`) — od tego zaczynasz, nie od czytania 900 linii.
Wariant bez babel: `esbuild.transformSync(src,{loader:'jsx'})`.
Python: `python3 -c "import ast; ast.parse(open(f).read())"` per plik.

## Krok 2 — LSP po patchu bywa NIEAKTUALNY
Po `patch` LSP potrafi zglosic zdublowana deklaracje, ktorej JUZ NIE MA.
Nie ufaj LSP-owi po edycji — potwierdz parserem (Krok 1) + `grep -n 'const agg'`.

## Krok 3 — lokalizuj zepsuty REGION przez diff wzgledem backupu
```
diff <(sed 's/[[:space:]]*$//' /tmp/<Nazwa>.bak) <(sed 's/[[:space:]]*$//' <plik>)
```
Diff pokazuje DOKLADNIE co subagent dodal. Czesto 90% dodatkow jest wartosciowe,
a zepsuty jest JEDEN fragment (dwa scalone warianty tej samej logiki:
zdublowana deklaracja `const agg`, osierocony `setUsers(...)`, niedomkniety `try`).
FIX: przepisz TYLKO zepsuty fragment (regula: region psuje sie 2x -> przepisz
fragment/funkcje), ZACHOWAJ dobre dodatki. Nie cofaj calego pliku do backupu.

## Krok 4 — weryfikacja per-wlasciciel projektu, nie repo-globalna
`npm run test` w ROOCIE repo testuje rdzen — nie zmieniony produkt.
Dla zmiany we frontendzie produktu uruchom test W TYM katalogu:
```bash
cd <produkt>/frontend && CI=true npm test -- --watchAll=false
```
Dla zmian backendu Python bez lokalnych deps (`ModuleNotFoundError: pydantic_settings`)
— weryfikuj STATYCZNIE: AST + dekoratory tras + rejestracje w main.py
(`grep -n include_router`), i nazwij wprost, ze import end-to-end jest
niedostepny lokalnie (BRAK POMIARU != PASS).

## Krok 5 — napraw tez CUDZE regresje ujawnione przez suite
Suite produktu moze wykryc regresje INNEGO agenta (plik `M` w git status).
Przyklad: inny agent przeszedl na URL relatywne (`fetch('/api/projects/')`),
a test zostal na absolutnych (`http://localhost:8000/api/...`). Rozstrzyga
`package.json "proxy"` = `http://localhost:8000` -> relatywne sa KANONEM.
FIX: popraw ASERCJE TESTU (plik committed, niska kolizja), NIE cudzy plik
zrodlowy bedacy w locie (wysoka kolizja). Wynik: 52/54 -> 54/54 PASS.

## Bramka "gotowe" dla zmiany JS/JSX (lancuch dowodow)
1. parser (babel jsx) -> 0 bledow skladni
2. `npx --no-install eslint <plik>` -> 0 errors (warnings kosmetyczne OK)
3. `npm run build` (realny toolchain, np. react-scripts) -> SUCCESS + artefakt
4. `npm test` w katalogu produktu -> zielone

# Warstwy konfiguracji agenta — pomiar po warstwach, nie po jednej

Zapis zmierzony 2026-09-28. Klasa problemu: **konfiguracja „działa", bo sprawdziłem
JEDNĄ warstwę, a konsument czyta inną.** To wariant §1c („mierzysz nie tę rolę")
i §3.1d („SSOT bez wymiaru"), ale na warstwach konfiguracji, nie na portach.

## Przypadek: persona monarchy działa w głosie, nie działa w czacie

Suweren zgłosił to **dwukrotnie** („nadal agenci nie zwracają się do mnie
z szacunkiem", potem „ale hermes też tego nie stosuje"), choć wcześniejszy audyt
ogłosił „system persony sprawny". Audyt mierzył warstwę, która była dobra.

### Pomiar po warstwach (dopiero to pokazało lukę)

```bash
for f in <workspace>/config/agent-identity.md \
         <workspace>/AGENTS.md \
         ~/.hermes/AGENTS.md ~/.qwen/AGENTS.md \
         ~/.claude/AIGON-AGENT-RULES.md ~/.grok/AGENTS.md; do
  [ -f "$f" ] && printf '%s  %s\n' \
    "$(grep -c 'PERSONA\|Królu Złoty\|Miłościwy Panie' "$f")" "$f"
done
```

Wynik:

| Warstwa | Wzmianek persony | Werdykt |
|---|---|---|
| `~/.qwen/AGENTS.md` | 5 | ✓ renderowane z SSOT |
| `~/.claude/AIGON-AGENT-RULES.md` | 5 | ✓ |
| `~/.grok/AGENTS.md` | 5 | ✓ |
| `~/.hermes/AGENTS.md` | 4 | ✓ |
| **`<workspace>/config/agent-identity.md`** | **0** | ✗ **LUKA** |
| `<workspace>/AGENTS.md` | 0 | (linkuje `@config/agent-identity.md`) |

### Dlaczego to umyka audytowi

Plik `agent-identity.md` **sam się deklaruje** jako źródło prawdy:

> „AIGON-X — UNIFIED AGENT IDENTITY. JEDNO źródło prawdy tożsamości dla
>  wszystkich agentów. Konsumenci: `~/.qwen/AGENTS.md`, `~/.claude/…`, …"

Ale **nie ma go w łańcuchu renderowania** (`grep agent-identity.md
scripts/sync-agent-models.py` → pusto) i nie zawiera persony. Agent uruchomiony
w katalogu `<workspace>` czyta **jego** (jako kontekst projektu), a nie pliki `~/.*`.
Deklaracja „jestem źródłem prawdy" ≠ bycie w łańcuchu dystrybucji.

### Naprawa i jej weryfikacja

Persona wchodzi jako **wiersz tabeli kanonu** (tabela = lista obowiązujących reguł,
więc to właściwe miejsce), z odsyłaczem do dokumentu źródłowego:

```markdown
| **Persona mowy** | mów do Suwerena po dworsku (klimat 1607) — rotacja tytułów,
  rejestr dworski; ostrze ZAWSZE w maszynę, nigdy w Króla |
  `config/PERSONA-MOWY.md` + skill `persona-monarchy-1607` |
```

Weryfikacja — **odsyłacz musi prowadzić do istniejącego pliku** (inaczej to kolejny
fałszywy trop):

```bash
grep -c 'Persona mowy' <workspace>/config/agent-identity.md    # >=1
ls -la <workspace>/config/PERSONA-MOWY.md                       # plik istnieje
grep -c 'Królu Złoty\|Miłościwy\|REJESTR DWORSKI' <workspace>/config/PERSONA-MOWY.md  # >=1
```

## Reguła ogólna

Gdy konsument zachowuje się tak, jakby konfiguracji **nie miał**:

1. **Wypisz WSZYSTKIE warstwy**, przez które ta konfiguracja może dojść — i policz
   wzmianki w każdej. Nie testuj tylko tej, którą sam zbudowałeś.
2. **Ustal, KTÓRĄ warstwę czyta ten konkretny konsument** w tym konkretnym
   kontekście (katalog roboczy ≠ katalog domowy). To jest pomiar tożsamości (§1c).
3. **Sprawdź, czy plik deklarujący się jako „źródło prawdy" jest w łańcuchu
   dystrybucji** — `grep <nazwa-pliku> <renderer>`. Deklaracja bez wpisu
   w propagatorze to sierota-mechanizm (§3.3b).
4. **Odsyłacz to nie treść** — jeśli naprawiasz przez pointer, zweryfikuj, że cel
   odsyłacza istnieje. Pointer do nieistniejącego pliku jest gorszy niż brak.

Objaw „dwie warstwy zielone, konsument i tak nie widzi" **nie znaczy**, że konsument
kłamie — znaczy, że mierzysz inną warstwę niż on czyta.

## Powiązane warianty tej samej klasy (ta sama sesja)

- **`--help` w rurze bywa PUSTE** (`timeout 120 cmd --help | head` → nic), bo
  proces ładuje torch/CUDA dłużej niż zdąży. Zapisuj do pliku:
  `timeout 120 cmd --help > help.txt 2>&1` — **pusty plik = nie zdążyło**, nie
  „brak flag". Wniosek „flaga nie istnieje" postawiony na pustym wyjściu rury
  jest fałszywy.
- **Ten sam port = różne usługi na różnych węzłach.** `:11435` na węźle z GPU to
  `python3` (guard), na węźle bez GPU — goła `ollama`. Zanim ogłosisz rozjazd,
  ustal TYP węzła. Szczegóły: `verification-guard-integrity` §3.1d.
- **`grep ':11435'` łapie też `<host>:11435`** — czyli „loopback nasłuchuje"
  bywa fałszem. Sprawdzaj wzorzec adresu, nie goły port (§1b).

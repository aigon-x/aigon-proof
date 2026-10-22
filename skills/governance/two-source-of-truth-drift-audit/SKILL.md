---
name: two-source-of-truth-drift-audit
description: "Wykrywaj i domykaj ROZJAZD, gdy to samo pojęcie liczy się z DWÓCH źródeł (graf vs manifest, core vs replica, spec vs kod, config A vs config B)."
---


# Rozjazd dwóch źródeł prawdy

## Przypadek zmierzony 2026-09-27: rejestr kanonu (pliki per-node vs wspólna baza)

Objaw: bramka `GATE-134 registry-coherence` **wiecznie FAIL** („pliki canon=41,
baza=42, 1 sierota: aio-okolic-connector"), a ręczne `DELETE` z bazy **działa i po
15 min wpis WRACA** → commit zablokowany WSZYSTKIM agentom.

Mechanizm (pomiar, nie domysł):
```
runtime/knowledge/canon/products/*  (PER-NODE, nie propagowane przez sync-prod)
        └─→ project-registry-sync.py (cron na KAŻDYM węźle) ─→ wspólna baza `aigon`.project_index
kanon istnieje TYLKO na site-aigon ─→ site zapisuje wiersz ─→ reszta mesha widzi SIEROTĘ
```
Dowód: `ls -d <workspace>/products/aio-okolic-connector` — brak na local, **jest** na
site-aigon (razem z katalogiem canon) → stąd `created_at` świeżo po każdym ticku.

Lekcje generalne:
1. **Zanim uznasz „nie da się naprawić", sprawdź, kto MA prawo pisać.** Gdy zapisuje
   N węzłów z lokalnych drzew do jednej bazy, jedynym rozwiązaniem jest wskazanie
   AUTORYTETU (`AIGON_REGISTRY_SSOT`, tu `local-aigon`): autor zapisuje, reszta czyta.
   Dodatkowo faza **prune** (usuń wiersze bez odpowiednika w źródle autorytatywnym) —
   inaczej wpis po rename/usunięciu zostaje w bazie na zawsze.
2. **`flock` w cronie NIE serializuje między węzłami** (`/var/lock` to osobny FS na
   każdym nodzie) → równoległe batche do jednej tabeli. Serializuj w BAZIE:
   `pg_advisory_xact_lock(hashtext('<klucz>'))`.
3. **Ubity klient zostawia `idle in transaction`, które trzyma blokady** (także advisory
   lock) i wywala kolejne przebiegi na wszystkich węzłach. Sprzątaj PRZED transakcją:
   `pg_terminate_backend` dla `state='idle in transaction' AND now()-state_change >
   interval '120 seconds' AND query LIKE '%<tabela>%'`.
4. **Kolejność w jednym batchu ma znaczenie:** advisory lock PRZED `SET LOCAL
   lock_timeout`, inaczej oczekiwanie na kolejkę samo kończy się `lock timeout`.
   I **żadnego wiodącego `ROLLBACK;`** poza transakcją — PostgreSQL da WARNING,
   a psql z `ON_ERROR_STOP=1` zwróci rc!=0 (sprzątanie wywala przebieg).
5. Bramka, która porównuje pliki z bazą, jest **dobra** — ale jej FAIL blokuje commit
   wszystkim, więc taki defekt to P1, nie kosmetyka.

## Wariant ostrzejszy: konsument ISTNIEJE, ale siedzi POZA ścieżką produkcyjną (2026-09-28)

Najpodstępniejsza odmiana tej klasy: **nic nie FAILuje**. Testy zielone, opis
produktu i dokumentacja twierdzą, że funkcja działa, a w uruchomionym produkcie
suwak nie robi NIC.

Zmierzone (gra Luau): `Config.World.FastNight` (tryb „SZYBKA NOC") miał
konsumenta — `PhaseMachine.phaseTime` — ale produkcja (`bootstrap.server →
ServerRuntime`) liczyła długość fazy **DRUGI RAZ**, wprost z
`Config.World.PhaseTime[phase]`. `PhaseMachine` wchodzi do gry tylko przez
`WorldSim`, czyli warstwę **referencyjną/oracle**, którą uruchamiają wyłącznie
testy. Skutek: suwak realnie nie istniał, a jedyny zestaw, który go mierzył, był
zielony — bo mierzył warstwę oracle, nie produkcję.

**Detekcja (3 komendy, ZANIM uznasz, że funkcja działa):**

```bash
# 1. kto czyta pole configu?
grep -rn "<Pole>" src/ | grep -v config/
# 2. czy KAŻDY z tych modułów JEST na ścieżce produkcyjnej? (tu: tylko WorldSim → oracle)
grep -rn "<Modul>" src/ | grep -v "^src/<sciezka>/<Modul>.lua"
# 3. gdzie produkcja liczy tę samą wartość DRUGI raz?
grep -n "<Tabela>\[" src/server/ServerRuntime.lua
```

Pytanie kontrolne: **„kto uruchamia ten moduł w produkcie?"**. Jeśli odpowiedź
brzmi „tylko testy / tylko warstwa referencyjna", to nie jest konsument — to alibi.

**Domknięcie:** eksport JEDNEJ funkcji liczącej wartość (tu `PhaseMachine.phaseTime`)
i wołanie JEJ z produkcji (`state.ends = os.clock() + PhaseMachine.phaseTime(phase)`).
Przy okazji scalania sprawdź, czy **komentarz nie kłamie o kodzie**, który
spłaszczasz (tu: komentarz twierdził „noc zostaje pełna", a kod skracał także noc).

**Strażnik klasy — para, bo runtime nie wstaje offline:**
(a) **behawioralnie** — uruchom PRAWDZIWY moduł i zmierz, że wartość zmienia
zachowanie (tu: DZIEŃ kończy się po `fast.Day` s, nie po `t.DAY`);
(b) **na kodzie produkcji** — test czyta źródło i wymaga wołania wspólnej funkcji
**oraz braku** drugiego obliczenia (`Config.World.PhaseTime[phase]`).
Punkt (b) to odczyt kodu, nie zachowanie — napisz to wprost w komentarzu testu,
żeby nikt nie wziął go za pomiar runtime'u. Razem tworzą parę „jest wykonawca"
+ „wykonawca robi to, co trzeba".

**Wniosek dla odbiorcy końcowego:** funkcja „opisana, a nieosiągalna" jest tym
samym defektem co fałszywy zielony. Zanim ogłosisz, że `Config`-owy suwak
działa, pokaż DOWÓD, że (1) produkcja go czyta i (2) użytkownik ma jak go
przełączyć (przełącznik w UI/klawisz) — sam suwak w configu to nie funkcja.

## Wariant: GENERATOR PATCHA nosi własną kopię SSOT (2026-09-28)

Trzecia odmiana tej klasy — **nic nie FAILuje i nic nie znika od razu**. Narzędzie
generuje człowiekowi fragment do wklejenia (patch do pliku konfiguracyjnego,
snippet, wpis do rejestru) i przy okazji **wypisuje własną kopię wartości, które
mają autorytet gdzie indziej**. Skutek jest odroczony: wklejenie patcha **cofa**
zmiany zrobione w SSOT — po cichu, bo nikt nie porównuje wygenerowanego tekstu
z configiem.

**Zmierzone:** `scripts/upload-audio-roblox.py` wypisywał gotowy patch do
`Config.lua` (`Sounds = { hit = { Group = "SFX", assetId = "", Volume = 0.7 } … }`).
Głośności i grupy miały **zaszyte w kodzie** (0.7/0.9/0.6/0.8…), z **fallbackiem
`0.7`** dla nieznanego zdarzenia, plus ostrzeżenie „Volume powyżej to placeholdery,
sprawdź oryginalne wartości". SSOT (`Config.lua`) był drugim źródłem — więc zmiana
głośności w Config powodowała, że patch niósł wartość **starą**, a wklejenie go
przywracało balans sprzed zmiany. Ostrzeżenie było przy tym nieprawdziwe: wartości
nie były placeholderami, tylko duplikatem (dodatkowo sugerowały ręczną edycję
„na oko" — czyli zaproszenie do trzeciego rozjazdu).

**Objaw rozpoznawczy:** narzędzie, które *wypisuje* fragment do wklejenia, ma
w sobie literały `= 0.7`, `= 300`, `:5432`, nazwy domyślne — **i default w
`dict.get(...)`/`or`/`??`**, którym zasłania brak wpisu. Fallback to najczęściej
właśnie ta kopia: brak wpisu w SSOT nie jest błędem, tylko cichym powrotem do
wartości wpisanej w kod generatora.

**Detekcja (tuż po przeczytaniu generatora):**

```bash
# 1. Czy generator CZYTA SSOT, czy nosi kopię?
grep -nE "= *[0-9]+\.[0-9]|\.get\(.*, *[0-9]|or +[0-9]" scripts/<generator>.py
# 2. Czy ostrzeżenie w wyjściu zgadza się z rzeczywistością?
grep -n "placeholder\|dostosuj\|sprawdź oryginalne" scripts/<generator>.py
# 3. Czy patch nosi wartość Z BIEŻĄCEGO SSOT? (patrz strażnik niżej)
```

**Domknięcie — generator CZYTA SSOT i nie ma prawa zgadywać:**

- grupa i wartość (tu: `Group`, `Volume`) oraz numer linii **czytane z pliku
  autorytatywnego** przy każdym uruchomieniu (`read_config_sounds()` → regex po
  bloku; zakres linii w nagłówku patcha liczony z realnego dopasowania, nie
  wpisany — inaczej dryf numerów po każdej edycji Config);
- **brak wpisu = GŁOŚNY BŁĄD**, nigdy fallback: `exit 1` + komunikat nazywający
  brakujące zdarzenie („Nie zgaduję głośności ani grupy i nie wypisuję patcha,
  który mógłby je po cichu zmienić"). Fallback jest tym, co czyni duplikat
  niewidocznym;
- w stopce patcha napisz wprost, **czego patch NIE zmienia** („Group i Volume
  przepisane 1:1 z Config.lua (SSOT); ten patch nie zmienia niczego poza assetId").

**Strażnik klasy (dowód negatywny jest tu obowiązkowy — inaczej nie odróżnisz
„czyta SSOT" od „przypadkiem zgadza się dzisiaj"):**

```python
# scripts/verify-audio-patch.py — wzorzec
old = 'hit = { Group = "SFX", assetId = "", Volume = 0.7 }'
new = 'hit = { Group = "SFX", assetId = "", Volume = 0.42 }'   # wartość MARKEROWA
CONFIG.write_text(src.replace(old, new, 1))
out = run(generator)
assert 'Volume = 0.42 }' in out.stdout        # niósł wartość z SSOT
assert 'Volume = 0.7 }'  not in out.stdout    # zero kopii/fallbacku
assert "placeholdery" not in out.stdout       # ostrzeżenie prawdomówne
# ... finally: CONFIG.write_bytes(orig); assert plik == orig (porównanie BAJTÓW)
```

Marker `0.42` (wartość, której nie ma w kodzie generatora) jest istotą testu:
przy 0.7 przeszedłby także duplikat. Sprawdzone: 7/7 PASS, `Config.lua` wrócił
1:1 co do bajtu. Ten sam strażnik uruchamiaj po każdej zmianie generatora —
dopisanie nowego zdarzenia bez wpisu w Config ma zapalać `exit 1`, nie default.

## Wariant: KONTRAKT vs ARTEFAKT — „nadwyżka", której nie ma (2026-09-29)

Objaw: audyt raportuje **rozjazd liczbowy** („implementacja ma **14**, kontrakt mówi
**13**; nadwyżką jest `X`"). Pozycja wisi w planie/audycie tygodniami, bo brzmi jak
„trzeba coś usunąć" — a nikt nie sprawdza, czy **teza z audytu jest jeszcze prawdziwa**.

Zmierzone (phoneguard, uprawnienia wariantu `consumer` vs kontrakt `SPEC-17`):

- **`X` (`FOREGROUND_SERVICE_LOCATION`) nie istniało** w żadnym wariancie — usunęła je
  wcześniejsza decyzja („decyzja B"), a **teza z audytu zamarła w planie fazy, w rejestrze
  ADR i w tabeli gotowości**. Nazwa „nadwyżki" przeżyła fakt (`grep` po `src/**` → 0 deklaracji;
  zostało tylko w komentarzu-tombstone i w **liście zakazanej** testu, który pada, gdyby wróciło).
- realna nadwyżka to **2 pozycje wstrzykiwane przez bibliotekę zależności** (`androidx.work`
  → `WAKE_LOCK`, `FOREGROUND_SERVICE`), których usunięcie **złamałoby produkt** — po decyzji B
  ta biblioteka jest JEDYNYM mechanizmem funkcji.

**Reguła rozstrzygająca (kolejność działań — nie odwracać):**

1. **Zanim cokolwiek usuniesz — zweryfikuj SAMĄ TEZĘ.** `grep` po źródłach i po **scalonym
   artefakcie**, nie po dokumentach, które tezę powtarzają. Odroczone ustalenie audytu jest
   **hipotezą**, nie faktem.
2. **Rozłóż liczbę na warstwy:** (a) deklaracje wariantu w źródłach, (b) wstrzyknięcia
   bibliotek (blame scalenia), (c) pozycje spoza licznika kontraktu (np. per-`applicationId`).
   Nazwij każdą pozycję z jej pochodzeniem.
3. **Usuń tylko to, co jest twoje i nieużywane.** Nadwyżkę zależnościową (brak ścieżki kodu,
   zero zdolności danych) **dopisuje się do kontraktu** jako *wyjątek infrastrukturalny* —
   z jawnym powodem: „usunięcie złamałoby <bibliotekę>, która jest jedynym mechanizmem <funkcji>".
4. **Kontrakt ma odzwierciedlać rzeczywistość** — popraw kontrakt + rejestr, **nie kod**, gdy
   kod jest prawdziwy a dokument nie. Odwrotnie niż w wariancie „generator nosi kopię".
5. **RIPPLE obowiązkowy.** Stara teza żyje zwykle w 3+ miejscach (plan/droga-do-produkcji,
   rejestr ADR, tabela gotowości audytu, graf celów). Popraw **wszystkie**, wstawiając jawną
   `KOREKTA <data>: powyższe ustalenie było BŁĘDNE …` z odesłaniem do nowego ADR — historia ma
   zostać czytelna („nic nie kasuj"), ale żadne miejsce nie może dalej uczyć fałszu.
6. **Sprawdź sąsiednią lukę tej samej klasy.** Tu wyszło, że jedna pozycja była **świadomie**
   w kodzie, ale **nie miała wiersza** w tabeli kontraktu (→ łamała kryterium „każde uprawnienie
   w scalonym manifescie ma wiersz"). Rozjazd liczbowy rzadko idzie sam.

**Pułapki:**
- Liczba policzona na źródle ≠ na **scalonym artefakcie builda** ≠ z `aapt dump` na APK — to trzy
  różne poziomy dowodu. W raporcie nazwij **ten, który realnie masz**, i nie nazywaj źródła „binarką".
- Nadwyżka rozłożona **symetrycznie** (`+1` w OBU wariantach) prawie zawsze znaczy „biblioteka",
  nie „dryf manifestu" — to poszlaka rozstrzygająca, nie szum.
- Pliki `build/intermediates/merged_manifest/` i `manifest_merge_blame_file/` mogą być **nieaktualne**,
  jeśli APK nie był budowany — sprawdź mtime lub przebuduj przed cytowaniem.

## Wariant: ta sama prawda w DWÓCH PROMPTACH do LLM (2026-09-29)

Czwarta odmiana — rozjazd siedzi nie w configu, tylko w **kodzie sklejającym prompt**.
Nic nie FAILuje i nic nie znika: model po prostu dostaje bezsens w jednym miejscu,
a w drugim poprawną wartość.

**Zmierzone (MONAI, autonomiczny freelancer, `<workspace>/products/monai/monai-job`):**

```
bidder/engine.py:147-148   f"Skills required: {', '.join(job.skills)}\n"
                           f"Budget: {job.budget_min}-{job.budget_max} {job.currency}\n"
builder/engine.py:402      f"Budget: {job.budget_min}-{job.budget_max} {job.currency}\n"
                           f"Required Skills: {', '.join(...)}\n"
```

Ten sam kontekst sklejany **niezależnie w dwóch plikach**, z tymi samymi defektami.
Skutek zmierzony na produkcyjnej bazie (`monai_job`):

| defekt | ile zleceń | co widział model |
|---|---|---|
| `budget_min`/`budget_max` = NULL | **161** | `Budget: None-None USD` |
| `skills` puste (`''`/`'[]'`) | **3729 (96%)** | `Skills required: ` — linia bez treści |
| `description` > limit | 46 + 30 | urwane w połowie zdania |

**Detekcja (jedno polecenie na cały produkt):**

```bash
grep -rn "Budget:\|Skills required:\|Job Title:" <repo>/monai/ --include="*.py"
# każdy trafiony plik = osobna kopia tej samej logiki kontekstu
```

**Domknięcie — JEDEN helper, nie poprawka w dwóch miejscach** (inaczej za tydzień
jedna ścieżka znów się rozjedzie):

```python
# monai/format_context.py — jedyne źródło prawdy o kształcie kontekstu
def format_budget(budget_min, budget_max, currency) -> str:
    lo, hi = budget_min, budget_max
    cur = (currency or "").strip()
    if lo is None and hi is None:
        return "Budget: nie podano (wycen samodzielnie wg rynku)"   # NIE "None-None"
    if lo is None: return f"Budget: do {hi:g} {cur}".strip()
    if hi is None: return f"Budget: od {lo:g} {cur}".strip()
    if lo == hi:   return f"Budget: {lo:g} {cur}".strip()
    return f"Budget: {lo:g}-{hi:g} {cur}".strip()

def format_skills(skills) -> str:
    # puste MUSI powiedzieć "nie podano" — goła linia to nie informacja dla modelu
    ...
```

Zasady, które wynikają z tego przypadku:
1. **NULL nie może przejść do promptu jako `None`.** Model nie odróżni „nie podano"
   od „wartość to tekst None" — dostanie bezsens i zacznie zgadywać.
2. **Brak danych to też informacja.** Zamiast pustej linii napisz `nie podano` —
   inaczej model milczy o tym, czego nie wie, i halucynuje.
3. **Obcinanie opisu tnij na granicy ZDANIA**, nie w połowie słowa (`rfind` po
   `. ! ? \n`, z progiem `> limit*0.6`), i dopisz `[opis skrócony]`.
4. **Test na helperze, nie na promptach** — 4 warianty budżetu (None/None, 500/None,
   None/750, 250/750) + puste skills + lista z pustymi elementami. Dowód: `"None" in txt == False`.

## Objaw rozpoznawczy (jeden z tych = prawdopodobnie ta klasa)

- Walidator/bramka **wiecznie FAIL**, a dane **wyglądają na obecne** („przecież to jest!")
- Ręczna naprawa **działa**, ale **automat nie** — i wraca przy następnej okazji
- `sync` / `reconcile` / `promote` raportuje sukces, a rozjazd **zostaje**
- Komunikat błędu porównuje **liczby** („140 < 141", „rdzeń 141 vs agenci 139") — czyli
  dwie strony liczą z różnych źródeł
- „Brak wpisu w manifeście NIE oznacza braku X" — zdanie, które **maskuje** rozjazd

## Wzorzec techniczny

```
ŹRÓDŁO A  ──→ GENERATOR ──→ plik A (np. graf)  ──→ WALIDATOR wymaga tego
ŹRÓDŁO B  ──→ RĘCZNIE   ──→ plik B (np. manifest) ──→ SYNC replikuje z tego

                  A ≠ B  ⇒  element w A, nieobecny w B  =  NIE DO DOSTARCZENIA
```

Kluczowe: **walidator i dystrybutor patrzą na RÓŻNE pliki.** Nikt nie porównuje A z B.

## Procedura (pomiar, nie domysł)

```bash
# 1. Który plik czyta WALIDATOR?
grep -n "def .*_core_set\|_set(\|read.*graph\|manifest" <walidator>

# 2. Który plik czyta DYSTRYBUTOR? (iteruj po źródle pętli!)
grep -n "for .* in .*items()\|in manifest\|in core" <dystrybutor>

# 3. Zrób RÓŻNICĘ ZBIORÓW — to jest cała diagnoza
python3 - <<'PY'
core    = set(...)   # to, czego wymaga walidator
present = set(...)   # to, z czego replikuje dystrybutor
print("w A bez B:", sorted(core - present))
print("w B bez A:", sorted(present - core))
PY
```

Gdy `core - present` jest niepuste i **stałe w czasie** → to rozjazd strukturalny,
nie przejściowy.

## Domknięcie: RECONCILE w potoku, nigdy ręką

Trzy warianty, od najlepszego:

1. **JEDNO źródło** — generuj B z A. Eliminuje klasę błędu u korzenia.
2. **RECONCILE w potoku** — skrypt uzgadniający A→B, idempotentny, wpięty jako
   **jawny krok z numerem** między generatorem a dystrybutorem. Nazwij krok
   komentarzem („KROK 1.6") i **potwierdź kolejność numerycznie**:
   ```bash
   LP=$(grep -n "promote"   potok | head -1 | cut -d: -f1)
   LR=$(grep -n "reconcile" potok | head -1 | cut -d: -f1)
   LS=$(grep -n "sync"      potok | head -1 | cut -d: -f1)
   [ "$LP" -lt "$LR" ] && [ "$LR" -lt "$LS" ] && echo "kolejnosc OK"
   ```
3. **Bramka na różnicę** — walidator porównuje A z B i FAIL-uje, gdy się rozjeżdżają.

**Wzorzec reconcile, który działa** (`scripts/skills-core-reconcile.py`):
- liczy core **tą samą funkcją** co dystrybutor (zero duplikacji logiki rdzenia)
- dla każdego elementu w A bez wpisu w B → dopisuje wpis wzorcem istniejących
- **idempotentny**: drugi przebieg musi dać `brak=0`
- `--dry-run` obowiązkowo przed pierwszym uruchomieniem
- **kopia pliku B przed edycją** (jeśli B jest duży/recznie pisany)

## PUŁAPKI (wszystkie realnie trafione)

### 1. Naprawa ręczna z `sudo` = ta sama choroba, którą leczysz
Jeśli wpisujesz brak do B **ręcznie**, klasa błędu wraca przy następnym elemencie.
Kanon: **„to miało być w pipeline"**. Wpinaj w potok, nie łataj pliku.
(Pytanie kontrolne użytkownika: „no przecież to miało być w pipeline, że używamy sudo?")

### 2. Naprawa objawu bez przyczyny
Dopisanie 2 brakujących wpisów **domyka FAIL**, ale **nie zamyka dziury** —
trzeci element zniknie tak samo. Zawsze pytaj: *dlaczego B nie dostał tego wpisu?*
I sprawdź **gdzie A bierze elementy, których B nie widzi** (`shared` vs katalogi agentów).

### 3. Pętla iteruje po INNYM zbiorze niż myślisz
```python
for name, entry in manifest.items():        # ← dystrybutor idzie po manifescie
    if core is not None and name not in core: continue   # ← a walidator po core
```
Obecność w `core` **nie wystarcza**, gdy pętla jest po `manifest`. Czytaj **nagłówek
pętli**, nie założenie.

### 4. Bramka, która ma to łapać, jest bezradna
Sprawdź, czy gate nie zwraca `WARN "nie mogę policzyć…"` albo nie siedzi w triggerze
**nieblokującym** (`cyclic:*`, `block_on_fail: false`). Bramka krzycząca od tygodni
i ignorowana **nie jest** bramką. Zmierzone: `context-budget` FAIL w trybie cyklicznym,
`agent-surface-parity` → `WARN` (sama nie umie policzyć).

### 5. Walidator porównuje SSOT ↔ powierzchnię, nie SSOT ↔ rejestr
Bramka może mówić „zgodne z SSOT", gdy element **leży w SSOT**, a nie dotarł do
**konsumenta** (baza/MCP/agent). Dwa różne końce łańcucha. Sprawdź, który koniec
bramka realnie bada.

### 6. Nie zgaduj nazw kolumn/kluczy — przeczytaj schemat
Realny koszt: założyłem `created_at`, schemat ma `timestamp` (REAL, unixepoch).
`sqlite3 <db> ".schema <tabela>"` **zanim** napiszesz zapytanie.

## Weryfikacja domknięcia (bez tego nie ogłaszaj sukcesu)

```bash
# 1. Rozjazd zniknął — reconcile mówi 0
python3 <reconcile>.py --dry-run      # → "bez wpisu … =0"

# 2. Dystrybutor REALNIE przeniósł elementy (nie "zgodny")
python3 <sync>.py 2>&1 | grep -E "CHG|skopiowany"

# 3. Bramka, która była FAIL, teraz przechodzi
python3 -m pytest <test_bramki> -q    # → wszystkie passed

# 4. Idempotencja — drugi przebieg nic nie zmienia
```
**Sukces ogłaszaj dopiero po punkcie 3.** Punkty 1–2 to warunki konieczne.

## Kontekst AIGON (gdzie to realnie wystąpiło)

| A (walidator) | B (dystrybutor) | Domknięcie |
|---|---|---|
| `skill-graph.yaml` rdzeń 141 | `agent-models.yaml` manifest | `skills-core-reconcile.py` KROK 1.6 |
| `--promote` z katalogów agentów | `skills/shared/` | reconcile uzupełnia manifest |

Objętość: rdzeń=141, agenci 139/141. Brakowało `telemetry-coverage-audit`,
`hermes-state-db-bloat-forensics` — oba w `shared` i w grafie, oba bez wpisu
w manifeście. Po reconcile: `agent-fabric` **15 passed**.

---
## SCALONE z two-source-of-truth-drift-audit/SKILL.md (2026-09-30) — 1 sekcji, których nie było w wersji bazowej

## Kolejność źródeł przy diagnozie (LAW-TOOL-1 / LAW-MEM-1)
Zanim zaczniesz `rg`/`find` — **ustal kolejność źródeł**, bo przeszukiwanie dysku
„na ślepo" pali minuty i DOWODZI NICZEGO nie o samym systemie:

1. **PAMIĘĆ** (notatki trwałe) — daje TROP, nie dowód;
2. **BAZA** (SQL / Postgres / SQLite) — stan faktyczny danych;
3. **MCP** (`skills_list`, `knowledge_search`, `memory_search`, `runtime_*`, `mesh_*`);
4. **DOPIERO pliki** — `rg` po **ZNANYM** zakresie (katalog produktu, nie `/`).

- **ZAKAZ `rg`/`find` po `/` albo całym dysku jako pierwszy krok.** `find /` potrafi
  zawiesić się na bind-mountach/NFS mesh (zmierzone: proces zawiśli na minutach).
- **PAMIĘĆ ≠ DOWÓD**: pamięć podaje trop, fakt potwierdzasz POMIAREM w źródle prawdy.
  Gdy pamięć przeczy teraźniejszości (np. „9 nodów" vs realne 6) — **rozstrzyga pomiar**.
- Bramka egzekwująca: `tools/gates/memory-first.sh` (SSOT `config/canonical/agent-memory.yaml`).

To ta sama klasa co reszta tego skilla: **dwa źródła prawdy o tym, „co wiemy"** (pamięć
vs pomiar) rozjeżdżają się cicho, jeśli nie nazwiesz, które jest autorytetem.

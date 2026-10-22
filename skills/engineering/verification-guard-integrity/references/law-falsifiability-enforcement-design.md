# Falsyfikowalna egzekucja praw/reguł — projekt (AIGON-X, 2026-09-29)

Materiał sesyjny do reguły: **prawo/reguła bez testu, który po wstrzyknięciu
błędu daje FAIL, NIE JEST prawem — jest dekoracją.** Dotyczy każdej klasy
„konstytucja/warstwa praw → bramki wykonawcze" (AIGON constitution.generated.yaml,
gates.yaml, policy-as-code), nie tylko AIGON.

## 0. Łańcuch egzekucji (co musi istnieć, żeby prawo było prawem)

```
proza/teza  →  rejestr maszynowy (law-id + fitness_cmd)  →  skrypt fitness (exit 0/1/2)
            →  trigger (hook/cron/CI)  →  meta-bramka pokrycia  →  RATCHET (pokrycie nie spada)
```

Luka, którą trzeba domknąć: **nikt nie sprawdza, czy fitness_cmd W OGÓLE potrafi
dać FAIL.** Meta-bramka pokrycia zbiera PASS/FAIL wykonawcy i akceptuje „PASS" —
a tautologiczny wykonawca zawsze zwraca 0. To przepuszcza martwe byty tygodniami.

## 1. Reguła ANTY-TAUTOLOGICZNA (najważniejsza)

> **Żaden fitness_cmd nie może brać baseline'u z tego samego pliku, który mierzy.**
> Porównanie musi iść: *deklaracja vs ŻYWY byt* (runtime/DB/rejestr), albo
> *zbiór A vs NIEZALEŻNY zbiór B*.

Zmierzone: bramka driftu porównywała liczbę kerneli z `manifest` z… tą samą
liczbą z `manifest` → „PASS (44)", runtime miał 35, **9 kerneli martwych**.
Manifest ≠ rejestracja. Porównanie deklaracja↔deklaracja to zawsze zielono.

Detekcja tautologii: w kroku mutacji (pkt 3) wstrzyknięcie ZMIENIA artefakt tak,
by deklaracja i pomiar się rozjechały — tautologia tego NIE wykryje i da 0 → FAIL.

## 2. Nowy SSOT: `config/canonical/<temat>-falsifiability.yaml`

```yaml
mutations:
  LAW-011:
    fitness_cmd: "tools/gates/fitness/law-011-measurement-truth.sh"
    mutate_cmd:  "tools/gates/fitness/mutations/law-011-drop-runtime.sh"
    expect_exit: 1   # po mutacji fitness MUSI dać 1 (FAIL)
    control_exit: 0  # bez mutacji MUST dać 0
```

Metryka do egzekwowania: **FALSIFIABILITY COVERAGE = prawa-PASS-falsyfikowalne /
prawa-z-wykonawcą.** Prawo z wykonawcą, ale bez mutacji, liczy się jako **0**
(nie „zaliczone") — nie dowiedliśmy, że wykonawca cokolwiek łapie.

## 3. Meta-harness `constitution-falsifiability.sh` (kontrakt)

Dla KAŻDEGO wpisu:
1. `cp -r` drzewo do `mktemp -d` (mutacja NIGDY nie dotyka produkcyjnego repo —
   współdzielonego przez wielu agentów).
2. fitness na czystej kopii → MUSI dać `control_exit` (0).
3. `mutate_cmd` (wstrzyknięcie naruszenia) → fitness → MUSI dać `expect_exit` (1).
4. kontrola=1 (fałszywie-czerwony) LUB mutacja=0 (błąd niewykryty) → **FAIL
   meta-bramki** + lista praw „nie-falsyfikowalnych".
5. wpięcie w `git:pre-push` (STANDARD) z RATCHET (baseline
   `<temat>-falsifiability.baseline`; liczba praw nie-falsyfikowalnych nie może
   ROSNĄĆ). Analizę statyczną (bez stanu żywego) wpinaj w `git:pre-commit` (FAST),
   by defekt łapał AUTOR, nie cała flota na push (wzorzec `gate-reachability`).

## 4. Pięć najważniejszych luk egzekucji (zmierzonych 2026-09-29)

| # | Luka | Łamane prawo (klasa) | Wykrycie automatyczne | Test falsyfikowalny (inject → FAIL) |
|---|---|---|---|---|
| 1 | Bramka porównywała manifest z manifestem (9 martwych kerneli PASS) | „brak pomiaru ≠ wynik" / self-report≠proof | deklaracja vs żywy runtime (API/DB); brak dowodu → exit 2, nigdy PASS | wstaw GHOST do manifestu (runtime go nie zna) → expect 1 z dowodem różnicy liczb |
| 2 | Test sprawdzał „job WYSTARTOWAŁ", nie „PRZETRWAŁ" (FAILED jako PASS) | acceptance-gate / measurement-truth | czytaj stan TERMINALNY (status==done, exit code, artefakt RESULT, brak FAILED/TIMEOUT/OOM) | job startuje i kończy FAILED → expect 1 |
| 3 | Kanon UBOŻSZY od kopii lokalnych (brak testu „kanon ⊇ lokalne") | discovery/rejestracja | `agent_set ⊆ canon_set` dla każdego katalogu agenta | wstaw skill poza kanonem → expect 1 (`kanon_nie_nadzbior`) |
| 4 | Skill w manifeście poza rdzeniem → sync PRUNE go usuwa | rejestracja / acceptance-gate | manifest⊆kanon ∧ kanon⊆rdzeń ∧ manifest⊆`skills_core.always` | dopisz `ghost-not-in-canon` do manifestu → expect 1; wpis poza always → expect 1 |
| 5 | Duplikat nazwy skilla u agenta (kolizja deterministycznego ID) | discovery / integralność | grupuj po `basename(dir)`; `len(paths)>1` = FAIL (`nama_duplikat`) | druga kopia tej samej nazwy pod innym rodzicem → expect 1 |

Wzorzec wspólny luk 3–5: **rejestr/graf jest konsumowany, ale nikt nie mierzy
relacji między ZBIORAMI** (kanon ↔ agent ↔ manifest ↔ rdzeń). „Ile jest" ≠ „czy
się zgadza".

## 5. Dowód falsyfikowalności w IZOLACJI (bez tykania produkcji)

Nadpisz korzenie env/flagą, zbuduj minimalne drzewo i pokaż dwa wyniki:

```bash
# kontrola: agent == kanon, bez duplikatu  → PASS / brak findingu  (exit 0)
AIGON_PROD_ROOT=/tmp/p python3 tools/gates/skill-registry-integrity.py --root /tmp/a
# iniekcja: ghost-skill poza kanonem       → FAIL kanon_nie_nadzbior  (exit 1)
mkdir -p /tmp/a/g2/ghost-skill; printf -- '---\nname: ghost-skill\n---\n' > /tmp/a/g2/ghost-skill/SKILL.md
AIGON_PROD_ROOT=/tmp/p python3 tools/gates/skill-registry-integrity.py --root /tmp/a   # exit 1
```

Zmierzony wynik: kontrola → `verdict PASS, test-findings []`; iniekcja → `FAIL
kanon_nie_nadzbior:['ghost-skill']`; realne drzewo → `exit 1` (103 duplikaty
w `~/.hermes`, 6 skilli poza kanonem).

## 6. Bramka wieloźródłowa (gotowy skrypt)

`scripts/skill-registry-integrity.py` w tym skillu — trzy checki (duplikat nazwy,
kanon ⊇ agent, manifest == rejestracja), kontrakt exit 0/1/2, flagi
`--json` / `--root` (do testów w izolacji). Uruchamiaj w `git:pre-commit`.

## 7. Wpięcie w pipeline (bez paraliżu współdzielonego repo)

- RATCHET zamiast progu 100% od razu: próg 100% postawiony, gdy 0/86 praw ma
  wykonawcę, **blokuje KAŻDY push całej flocie** — to paraliż, nie egzekucja.
  Wzorzec: dług zastany = WARN, tylko maleje.
- Mutacje wyłącznie w `mktemp -d`. Nigdy na produkcji.
- **Współdzielone repo:** w trakcie tej sesji plik bramki został rozszerzony
  przez RÓWNOLEGŁEGO agenta (doszedł check LUKA-6) między moim zapisem a
  uruchomieniem → `Permission denied`, potem urósł z 7,8 KB do 19,8 KB.
  Edycje artefaktów współdzielonych rób atomowo (`mktemp` + `mv`); patrz
  skill `parallel-agent-shared-repo-ops`.
---
name: agent-live-reload-and-prompt-freshness
description: "Użyj, gdy zmiana promptu/konfiguracji/pluginu agenta JEST w plikach i przechodzi testy na świeżym procesie, ale ŻYWA sesja działa po staremu (objaw nie znika, delegacja dalej wysyła stary payload..."
tags: [hermes, hot-reload, prompt, cache-invalidation, gateway, plugins, agents, ssot]
related_skills: [skill-index-prompt-budget, hermes-output-hooks, generated-artifact-and-cron-safety, hermes-runtime-source-of-truth]
---


# Live reload i świeżość promptu agenta

## Kiedy użyć

- Poprawka pliku (prompt builder, config, plugin, SSOT) **działa na świeżym procesie**,
  a **żywa sesja zachowuje się jak przed zmianą**. Objaw „zmiana nie działa" przy zielonych testach.
- Zmierzone 2026-10-01: `names_only_all` w `prompt_builder.py` dawał −60 % indeksu w teście
  świeżego procesu, a **żywa delegacja dalej wysyłała ~40 000 tokenów → HTTP 413**.
- Użytkownik mówi „miał być hot reload dla agentów", „i to dla każdego agenta", „wszystkich".
- Plugin `enabled`, ale hook nie działa — np. filtr emitowanych znaków nie łapie przecieku.

## Model warstw — USTAL, KTÓRA trzyma stare (nie restartuj na ślepo)

Zmiana wchodzi „za darmo" albo wymaga interwencji zależnie od warstwy. Diagnozuj po kolei:

| # | Warstwa | Co trzyma stary stan | Wchodzi sama? |
|---|---|---|---|
| 1 | **Kod rdzenia w pamięci procesu** | Python załadował moduł raz; `prompt_builder.py`, `system_prompt.py`, `agent_init.py` | **NIE** — wymaga restartu procesu |
| 2 | **Cache configu** | `hermes_cli/config.py`: `_LOAD_CONFIG_CACHE` / `_RAW_CONFIG_CACHE`, klucz `(path, mtime_ns, size)` | **TAK** — mtime-based, sam się unieważnia |
| 3 | **Snapshot indeksu skilli** | `~/.hermes/.skills_prompt_snapshot.json` (w `~/.hermes/`, NIE w `skills/`) | **NIE** — dopóki manifest mtime/size się zgadza |
| 4 | **Cache niezależny od parametru** | np. `_SKILLS_PROMPT_CACHE` w `prompt_builder.py` | **NIE** — jeśli parametr nie ma go w kluczu (patrz niżej) |
| 5 | **Cache agentów w gateway** | `gateway/run.py`: `self._agent_cache` (`OrderedDict` per sesja) trzyma `_cached_system_prompt` | **NIE** |
| 6 | **Plugin zarejestrowany po starcie sesji** | `hermes plugins enable` → „Takes effect on next session" | **NIE** |
| 7 | **SSOT → render plików agentów** | `sync-agent-models.py` pisze, ale **świadomie nie restartuje** (co 15 min) | **Częściowo** — pliki tak, proces nie |

Bramka rozstrzygająca — jedno polecenie na warstwę 1 vs resztę:

```bash
# czy zmiana jest w PLIKU (warstwy 2-7) czy potrzebny restart KODU (warstwa 1)?
grep -c '<twoj_nowy_symbol>' ~/.hermes/hermes-agent/agent/prompt_builder.py
ps -o pid,lstart,cmd -C python3 | grep -E 'gateway|hermes'   # kiedy proces wstal vs mtime pliku
```

**Reguła:** jeśli `mtime(kod) > lstart(proces)` → warstwa 1, **restart nieunikniony**.
Jeśli zmiana jest tylko w DANYCH (config, snapshot, plugin, SSOT) → **da się bez restartu**.

## Czego NIE MA (nie szukaj na darmo) — zmierzone

- `hermes config reload` — **nie istnieje** (komendy: show/edit/get/set/unset/path/check/migrate).
- Handler `SIGHUP` w gateway — **nie istnieje**. `gateway/shutdown_forensics.py` jedynie *loguje*
  napotkane sygnały; `kill -HUP` = śmierć procesu = **utrata kontekstu aktywnych rozmów**.
  Nigdy nie „restartuj sygnałem" cudzej żywej sesji.
- `sync-agent-models.py` **świadomie** nie restartuje serwisu przy każdym syncu (komentarz w kodzie:
  „Nie restartuje serwisu przy kazdym syncu (co 15 min)") — stąd zmiany czekają, aż ktoś wymusi.

## Kanoniczny hot reload — `scripts/agent-hot-reload.py`

**Gotowy do uruchomienia:** `scripts/agent-hot-reload.py` w tym skillu — skopiuj do
`<workspace>/scripts/`, dostosuj `W1_FILES` do układu na hoście (**sprawdź `ls`, nie zgaduj**
ścieżek). Tryby: `--status` (co nieaktualne), `--force` (wymuś), bez argumentu (watch).

Wzorzec: **plik-znacznik + unieważnienie cache + wymuszony sync**, wołany z crona co minutę.
Nie zabija procesu; nowe sesje czytają świeży stan.

Trzy warstwy detekcji (sygnatura = sha256 z `(path, mtime_ns, size)`, jak `_build_skills_manifest`):

```python
W1_FILES   # dane promptu: config.yaml, AGENTS.md, memories/*.md, snapshot skilli,
           #   + PLIKI TOŻSAMOŚCI I KONFIGI CAŁEJ RODZINY AGENTÓW
W1_CODE    # kod rdzenia -> zmiana = WYMAGA RESTARTU (raportuj wprost, nie udawaj że nie)
W1_PLUGINS # ~/.hermes/plugins -> hooki (transform_llm_output) nie wchodzą w żywą sesję
W2_SSOT    # config/agent-models.yaml -> wymuś sync-agent-models.py natychmiast
```

Akcje przy wykryciu zmiany:
1. `W2` → uruchom `sync-agent-models.py` (nie czekaj na okno 15 min).
2. `W1_FILES` → usuń `~/.hermes/.skills_prompt_snapshot.json` (z kopią), postaw znacznik.
3. `W1_CODE` → **zamelduj, że potrzebny restart gateway** — z PID-em. Nie połykaj tego.

Rodzina agentów do objęcia watcherem (zmierzone, istnieją na hoście):
`~/.qwen/AGENTS.md`, `~/.claude/AGENTS.md`, `~/.claude/AIGON-AGENT-RULES.md`, `~/.grok/AGENTS.md`,
`~/.codex/AGENTS.md`, `~/.dsh/AGENTS.md`, `~/.aigon/AGENTS.md`, `~/.hermes/AGENTS.md`
+ konfigi per agent: `~/.qwen/settings.json`, `~/.grok/config.toml`, `~/.aigon/profiles.json`.

Cron (SSOT `config/cron.yaml`, `sync-cron.py` propaguje do `/etc/cron.d`):

```yaml
- schedule: "* * * * *"
  command: "<workspace>/scripts/cron-run.sh agent-hot-reload 160 -- python3 <workspace>/scripts/agent-hot-reload.py"
  user: sniegul
```

Wzorzec watchdoga: **cichy, gdy brak zmian** (żadnego stdout = brak szumu), a pierwszy przebieg
tylko ustanawia baseline. Błąd odczytu lub przeładowania MUSI dać niezerowy kod
wyjścia i mierzalny sygnał błędu; nie zamieniaj wyjątku w `exit 0`. Zachowaj ostatni
poprawny stan z jawnym wiekiem/TTL, ale nie przedstawiaj go jako świeżego sukcesu.

## PUŁAPKA KLASY — parametr poza kluczem cache = zmiana MARTWA

Najczęstsza przyczyna „poprawka nie działa" w tej klasie: **nowy parametr renderu nie wszedł
do klucza cache**, więc wywołanie z nową wartością trafia w stary wynik.

Zmierzone 2026-10-01 (`agent/prompt_builder.py`): dodanie `names_only_all` do sygnatury bez
dopisania go do `cache_key` dawało **FULL == NAMES**, 0 oszczędności. Poprawka:

```python
cache_key = (..., tuple(sorted(compact_categories or ())),
             bool(names_only_all))   # <- każdy parametr wpływający na render MUSI tu być
```

Objaw diagnostyczny: **dwa różne argumenty zwracają identyczny wynik**. To zawsze podejrzane.
Klasa ogólniejsza: wynik zależny od KOLEJNOŚCI wywołań, nie od argumentów.

## Weryfikacja po hot reloadzie (na ŚWIEŻYM procesie)

Nie da się zweryfikować zmiany kodu rdzenia w trwającej sesji — kod jest już w pamięci.
Poprawny test, przez **venv Hermesa** (nie systemowy `python3`):

```bash
~/.hermes/hermes-agent/venv/bin/python -c '
import sys; sys.path.insert(0,"/home/sniegul/.hermes/hermes-agent")
from agent.prompt_builder import build_skills_system_prompt
f = build_skills_system_prompt(); n = build_skills_system_prompt(names_only_all=True)
print(len(f)//4, len(n)//4, f != n)   # rozne liczby + True = dziala
'
```

I dowód end-to-end: **nowa delegacja po restarcie** — sprawdź live transcript
(`~/.hermes/cache/delegation/live/<deleg_id>/task-N.log`) na `tool |` (realne wywołania)
oraz `413`. Dla zadania wymagającego narzędzi brak rzeczywistych wywołań oznacza
brak dowodu wykonania. Zwykła odpowiedź konwersacyjna może poprawnie nie używać
narzędzi; sam brak `tool |` nie dowodzi awarii komunikacji.

## Pitfalls

- **NIE weryfikuj przez `python3` systemowy.** Hermes działa w `~/.hermes/hermes-agent/venv`.
  Zmierzone 2026-10-01: `pytest` uruchomiony systemowym `python3` dał **1 FAIL**
  (`ModuleNotFoundError: No module named 'requests'`) — fałszywy alarm; ten sam test
  w venv → **190 passed**. Zły interpreter = fałszywy czerwony.
- **`hermes plugins enable` nie działa wstecz.** Plugin `enabled` w configu, ale sesja
  wystartowała wcześniej → hook **nie jest wpięty**. Zmierzone: filtr CJK „enabled",
  a przeciek i tak dotarł do użytkownika. Sprawdź `lstart` sesji vs moment rejestracji.
- **Zmiana kodu rdzenia ≠ zmiana danych.** Kod (warstwa 1) zawsze wymaga restartu.
  Zawsze raportuj wprost „potrzebny restart", zamiast sugerować, że hot reload załatwił sprawę.
- **Restart gateway to restart cudzych rozmów.** `hermes-gateway.service` (unit **user**, nie
  systemowy); przed restartem upewnij się, że nie przerywasz aktywnej pracy. Preferuj hot reload.
- **Nie zgaduj ścieżki snapshotu.** Jest w `~/.hermes/.skills_prompt_snapshot.json`,
  **nie** w `~/.hermes/skills/`. Sprawdź `_skills_prompt_snapshot_path()` w kodzie.
- **Rozjazd interpreterów to osobna klasa.** `python3` dla `root` = `/usr/bin/python3` (systemowy),
  dla użytkownika = `~/.local/bin/python3` (uv). Ten sam skrypt → **inny interpreter** zależnie
  od tego, kto go uruchamia. Objaw: czujnik raportuje raz `3.12.3`, raz `3.11.15`.

## Powiązane

- `skill-index-prompt-budget` — co dokładnie siedzi w payloadzie i jak go ciąć (413/TPM).
- `hermes-output-hooks` — plugin `transform_llm_output`: dlaczego shell hook nie podmieni treści.
- `hermes-runtime-source-of-truth` — która kopia kodu faktycznie się uruchamia (pokrewna klasa).
- `generated-artifact-and-cron-safety` — równoległe commity i lock indeksu gita.

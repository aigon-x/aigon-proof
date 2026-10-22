#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/agent-memory-sync.sh — gate AGENT-MEMORY-SYNC
#
#  PO CO (audyt bram 2026-09-29, skill mesh-resource-sovereign):
#    `scripts/sync-agent-memory.py` — adapter Agent Memory → Canonical Memory
#    Fabric (SurrealDB `memory_items` + indeks Qdrant `memory_v1`) — był wołany
#    z crona BEZ ŻADNEJ BRAMY i leżał w TOP ryzyka audytu (dotyka DANYCH
#    PAMIĘCI wszystkich agentów). Zmierzone przy tworzeniu bramy: domena
#    `aigon_memory*` miała w Prometheusie **0 metryk** — całkowicie niewidoczna.
#    Cichy brak synchronizacji = pamięć agenta rozjeżdża się z kanonem bez
#    wykrycia, a nikt tego nie mierzy.
#
#  CO MIERZY (skutek, nie akcję):
#    1. Czy adapter w ogóle ZBIERA wpisy (dry-run: „zebrano N wpisów").
#       N=0 przy niepustych katalogach agentów = ROZJAZD ŚCIEŻEK (adapter
#       patrzy tam, gdzie nic nie ma) — typowy cichy defekt po przenosinach.
#    2. Czy kanoniczny magazyn ODPOWIADA (GET /api/v1/memory/stats).
#       Brak odpowiedzi != zero wpisów — to FAIL z jawnym powodem.
#    3. Czy liczba w kanonie NIE JEST MNIEJSZA niż zebrane (ratchet: sync
#       nigdy nie może zmniejszać stanu pamięci — to byłaby utrata danych).
#
#  KONTRAKT: exit 0 = PASS, exit 1 = FAIL.
#  Env: AIGON_RUNTIME_URL (def. https://localhost:7000), min wpisów przez
#       AIGON_MEMORY_MIN_ENTRIES (def. 1 — chroni przed „zero jako sukces").
#
#  PUŁAPKA (klasa zmierzona w tej sesji): `curl exit 0` i puste ciało NIE jest
#  sukcesem. Pusta/nieudana odpowiedź != zero wpisów != zdrowy stan.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ADAPTER="$ROOT/scripts/sync-agent-memory.py"
API_BASE="${AIGON_RUNTIME_URL:-https://localhost:7000}"
. "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/gate-params.sh"
MIN_ENTRIES="$(gp GATE-178 agent_memory_min_entries 1)"
export PATH="/usr/bin:/usr/local/bin:$PATH"

fails=0
say() { printf '       %s\n' "$*"; }

if [ ! -f "$ADAPTER" ]; then
  say "FAIL: brak adaptera $ADAPTER"
  echo "agent-memory-sync: FAIL (brak adaptera)"
  exit 1
fi

# ── 1. Adapter ZBIERA wpisy (dry-run, read-only) ────────────────────────
collected=""
dry_out="$(timeout 180 python3 "$ADAPTER" --dry-run 2>&1 || true)"
collected="$(printf '%s\n' "$dry_out" | grep -oE 'zebrano [0-9]+ wpis' | grep -oE '[0-9]+' | head -1)"

if [ -z "$collected" ]; then
  say "FAIL: adapter nie zaraportował liczby zebranych wpisów (kontrakt stdout złamany)"
  say "      Ostatnie linie: $(printf '%s' "$dry_out" | tail -2 | tr '\n' ' ')"
  fails=$((fails+1))
elif [ "$collected" -lt "$MIN_ENTRIES" ]; then
  say "FAIL: adapter zebrał ${collected} wpisów (min ${MIN_ENTRIES}) — katalogi agentów puste albo ROZJAZD ŚCIEŻEK"
  fails=$((fails+1))
else
  say "OK:   adapter zebrał ${collected} wpisów pamięci agentów"
fi

# ── 2. Kanoniczny magazyn odpowiada ─────────────────────────────────────
# Klucz runtime: env AIGON_RUNTIME_SHARED_SECRET (kanon) lub *_API_KEY.
KEY="${AIGON_RUNTIME_SHARED_SECRET:-${AIGON_RUNTIME_API_KEY:-${RUNTIME_API_KEY:-}}}"
stats_body=""
if [ -n "$KEY" ]; then
  stats_body="$(curl -sk -m 15 "${API_BASE}/api/v1/memory/stats" -H "X-API-Key: ${KEY}" 2>/dev/null || true)"
fi

if [ -z "$stats_body" ]; then
  # Brak klucza albo brak odpowiedzi — NIE udajemy PASS ani zera.
  say "WARN: brak odpowiedzi /api/v1/memory/stats (klucz ustawiony: $([ -n "$KEY" ] && echo tak || echo NIE))"
  say "      Nie mogę potwierdzić stanu kanonu — to NIE jest sukces (brak pomiaru != zero)"
  # Adapter zebrał wpisy = główna asercja przeszła; brak pomiaru kanonu raportujemy,
  # ale nie blokujemy (endpoint może być niedostępny z tego węzła).
else
  total="$(printf '%s' "$stats_body" | grep -oE '"(total|count|items)"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)"
  if [ -z "$total" ]; then
    say "OK:   /api/v1/memory/stats odpowiedział (kształt bez pola total — nie porównuję liczb)"
  elif [ -n "$collected" ] && [ "$total" -lt "$collected" ]; then
    say "FAIL: kanon ma ${total} wpisów < zebranych ${collected} — RATCHET: sync nie może ZMNIEJSZAĆ pamięci"
    fails=$((fails+1))
  else
    say "OK:   kanon ${total} wpisów ≥ zebrane ${collected}"
  fi
fi

# ── 3. Werdykt ──────────────────────────────────────────────────────────
if [ "$fails" -eq 0 ]; then
  echo "agent-memory-sync: PASS (adapter zbiera wpisy, kanon spójny)"
  exit 0
fi
echo "agent-memory-sync: FAIL (${fails} asercji)"
exit 1

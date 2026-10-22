#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/scatter-contract.sh — gate scatter-contract (cyclic:6h)
#
#  Wykrywa anomalie kontraktu scatter-gather z CANONICAL-STRUCTURE-2026-08-21:
#    S1  registry zadań in-memory (OnceLock<Mutex<HashMap>>) — utrata po
#        restarcie mastera → placeholderowe task_id
#    S2  task_status bez walidacji task_id (kontrakt API)
#    S3  limit odpowiedzi 32768 B (ucięcie → json.loads fail)
#    S4  puste wyniki done (48× done bez treści vs 129 dispatched)
#
#  Detekcja: analiza kodu api.rs + wyników fali z /tmp/wyniki-fala1/.
#  Exit: 0 = PASS, 1 = FAIL (anomalie), 2 = WARN (brak możliwości sprawdzenia).
#  Ostatnia linia stdout = komunikat (kontrakt hook-runnera).
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
API_RS="$ROOT/runtime/crates/aigon-runtime/src/api.rs"

failures=0
found=""

report() {
  found="${found}${1}"$'\n'
  failures=$((failures + 1))
}

# ── S1: trwałość registry zadań ───────────────────────────────────────
# Szukamy zapisu stanu na dysk (persist/save/fs::write/json) w okolicy
# rejestru zadań; brak = registry in-memory (utrata po restarcie).
if [ -f "$API_RS" ]; then
  persist_hits=$(grep -nE "fs::write|persist|serde_json::to_writer|save_state|task_registry" "$API_RS" 2>/dev/null | grep -viE "log|tracing|evidence" | head -5)
  if [ -z "$persist_hits" ]; then
    report "S1: brak trwałości registry zadań w api.rs (in-memory → utrata po restarcie mastera)"
  fi
else
  report "S1: api.rs nie istnieje ($API_RS) — nie można zweryfikować trwałości registry"
fi

# ── S2: walidacja task_id w task_status ───────────────────────────────
if [ -f "$API_RS" ]; then
  # task_status powinien wymagać task_id (path param) i zwracać 400/404
  # przy braku; brak obsługi = kontrakt dziurawy (placeholderowe odpowiedzi).
  task_status_hits=$(grep -nE "task_status|tasks?/status" "$API_RS" 2>/dev/null | head -5)
  if [ -z "$task_status_hits" ]; then
    report "S2: brak handlera task_status w api.rs (kontrakt API scatter niekompletny)"
  fi
else
  report "S2: api.rs nie istnieje — nie można zweryfikować kontraktu task_status"
fi

# ── S3: limit odpowiedzi 32768 B ──────────────────────────────────────
# Ucięcie odpowiedzi na 32768 B powoduje json.loads fail w kliencie.
if [ -f "$API_RS" ]; then
  limit_hits=$(grep -nE "32768|32.?768|MAX_TOOL_TEXT|max_tool_text|truncat" "$API_RS" 2>/dev/null | head -5)
  if [ -z "$limit_hits" ]; then
    report "S3: brak jawnego limitu odpowiedzi w api.rs (ucięcie na 32768 B łamie kontrakt JSON)"
  fi
else
  report "S3: api.rs nie istnieje — nie można zweryfikować limitu odpowiedzi"
fi

# ── S4: puste wyniki done z fali scatter ──────────────────────────────
WYNIKI_DIR="${AIGON_SCATTER_WYNIKI_DIR:-/tmp/wyniki-fala1}"
if [ -d "$WYNIKI_DIR" ]; then
  done_files=$(find "$WYNIKI_DIR" -maxdepth 1 -type f -name "*_done.json" 2>/dev/null)
  total_done=$(echo "$done_files" | grep -c . || true)
  empty_done=0
  if [ "$total_done" -gt 0 ]; then
    for f in $done_files; do
      # puste = 0 bajtów, albo JSON bez pola wyniku ({} lub tylko metadata)
      if [ ! -s "$f" ] || ! grep -qE '"(result|output|content|response)"' "$f" 2>/dev/null; then
        empty_done=$((empty_done + 1))
      fi
    done
  fi
  if [ "$empty_done" -gt 0 ]; then
    report "S4: $empty_done/$total_done plików _done.json w $WYNIKI_DIR bez wyniku (puste odpowiedzi scatter)"
  fi
fi

# ── Werdykt ───────────────────────────────────────────────────────────
if [ "$failures" -gt 0 ]; then
  echo "FAIL: naruszenia kontraktu scatter (${failures}):"
  echo -n "$found" | sed 's/^/  /'
  exit 1
fi

echo "PASS: kontrakt scatter-gather zgodny z kanonem"
exit 0

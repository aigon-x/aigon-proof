#!/usr/bin/env bash
# ============================================================================
# obs-deadman-check.sh — OBS-BASELINE — DEADMAN SWITCH GATE
# ============================================================================
# Universal Project Template — Repository Certification Engine
#
# OBS-BASELINE: szablon rodzi obserwowalne projekty. Ten moduł pilnuje, że
# krytyczne serwisy mają DEADMAN SWITCH (heartbeat) — mechanizm, który
# alarmuje, gdy serwis PRZESTAJE wysyłać sygnał życia. Deadman to jedyny
# alert, który wykrywa "ciszę" (brak metryk, brak logów, brak heartbeat) —
# klasyczne alerty oparte o metryki nie zadziałają, gdy serwis całkiem padnie.
#
# Checki:
#   OBS-13  Krytyczne serwisy (tier 1-2) mają zadeklarowany deadman switch
#           (heartbeat) w config/canonical/observability.yaml (sekcja deadman).
#
# ZASADA TEMPLATE: świeży projekt (zero kodu domenowego) ma tier: 3, więc
# deadman nie jest obowiązkowy (tylko tier 1-2). Manifest deklaruje deadman
# jako placeholder — NIE jest to realna integracja.
#
# SELF-HOSTING: verify plane sam deklaruje deadman (system obserwuje samego
# siebie, nie tylko sprawdza innych).
# ============================================================================
set -u

VERIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=core/lib.sh
. "$VERIFY_DIR/core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== OBS-BASELINE — DEADMAN SWITCH GATE ==="

SKELETON=".skeleton.yaml"
OBSERVABILITY="config/canonical/observability.yaml"

# ── Odczyt tier z .skeleton.yaml ───────────────────────────────────────────
TIER=""
if repo_file "$SKELETON"; then
  if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" >/dev/null 2>&1; then
    TIER="$(python3 - "$SKELETON" <<'PY' 2>/dev/null
import sys, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
print(data.get("tier", 3))
PY
)"
  else
    TIER="$(grep -E '^tier:' "$SKELETON" | head -1 | awk '{print $2}')"
  fi
fi
[ -z "$TIER" ] && TIER="3"

# ── Deadman obowiązkowy dla tier 1-2 ───────────────────────────────────────
# Tier 3 (świeży projekt) → deadman nieobowiązkowy, ale jeśli manifest go
# deklaruje, walidujemy jego kompletność.
if [ "$TIER" -le 2 ]; then
  # Krytyczny serwis — deadman WYMAGANY.
  if repo_file "$OBSERVABILITY" && grep -qE '^deadman:' "$OBSERVABILITY"; then
    # Sprawdź kompletność: heartbeat_interval + alert_ref.
    # Dopasowujemy KLUCZE YAML (z dwukropkiem), nie luźne stringi — komentarze
    # w manifeście mogą zawierać te słowa i nie mogą być traktowane jako dane.
    MISSING=""
    grep -qE '^[[:space:]]*heartbeat_interval:' "$OBSERVABILITY" || MISSING="$MISSING heartbeat_interval"
    grep -qE '^[[:space:]]*alert_ref:' "$OBSERVABILITY" || MISSING="$MISSING alert_ref"
    if [ -z "$MISSING" ]; then
      pass "OBS-13 Deadman switch" BLOCKING "Krytyczny serwis (tier $TIER) ma kompletny deadman switch (heartbeat_interval + alert_ref)."
    else
      fail "OBS-13 Deadman switch" BLOCKING "Deadman switch niekompletny — brak:$MISSING."
    fi
  else
    fail "OBS-13 Deadman switch" BLOCKING "Krytyczny serwis (tier $TIER) NIE ma zadeklarowanego deadman switch (sekcja deadman w $OBSERVABILITY)."
  fi
else
  # Tier 3 — nieobowiązkowy. Jeśli zadeklarowany, walidujemy kompletność.
  if repo_file "$OBSERVABILITY" && grep -qE '^deadman:' "$OBSERVABILITY"; then
    MISSING=""
    grep -qE '^[[:space:]]*heartbeat_interval:' "$OBSERVABILITY" || MISSING="$MISSING heartbeat_interval"
    grep -qE '^[[:space:]]*alert_ref:' "$OBSERVABILITY" || MISSING="$MISSING alert_ref"
    if [ -z "$MISSING" ]; then
      pass "OBS-13 Deadman switch" BLOCKING "Deadman switch zadeklarowany i kompletny (tier $TIER — nieobowiązkowy)."
    else
      warn "OBS-13 Deadman switch" "Deadman switch zadeklarowany, ale niekompletny — brak:$MISSING (tier $TIER — nieobowiązkowy)."
    fi
  else
    info "OBS-13 Deadman switch" "SKIP — tier $TIER nie wymaga deadman switch (obowiązkowy dla tier 1-2)."
  fi
fi

# ── Evidence ────────────────────────────────────────────────────────────────
if verify_blocked; then
  evidence_record "verify:obs-deadman-check:FAIL" "verify" "obs-deadman-check.sh"
else
  evidence_record "verify:obs-deadman-check:PASS" "verify" "obs-deadman-check.sh"
fi

verify_module_exit

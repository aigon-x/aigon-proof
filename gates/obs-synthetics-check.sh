#!/usr/bin/env bash
# ============================================================================
# obs-synthetics-check.sh — OBS-BASELINE — SYNTHETICS GATE
# ============================================================================
# Universal Project Template — Repository Certification Engine
#
# OBS-BASELINE: szablon rodzi obserwowalne projekty. Ten moduł pilnuje, że
# projekt eksponujący HTTP (web: true) ma syntetyki — sztuczne żądania, które
# sprawdzają, że endpointy działają z zewnątrz. Syntetyki wykrywają awarie,
# których nie złapią wewnętrzne healthz/readyz (np. zepsuty routing, CDN,
# firewall).
#
# Checki:
#   OBS-16  Projekt web:true MUSI mieć zadeklarowane syntetyki.
#
# WARUNKOWOŚĆ: moduł czyta flagę `web` z .skeleton.yaml.
#   * web: false → SKIP + evidence N/A (projekt nie eksponuje HTTP).
#   * web: true  → sprawdza, że syntetyki są zadeklarowane (OBS-16).
#
# ZASADA TEMPLATE: świeży projekt (zero kodu domenowego) ma web: false,
# więc moduł robi skip. Placeholdery syntetyków NIGDY nie są realnymi
# żądaniami (self-scan — sprawdzamy deklarację, nie żywotność).
#
# SELF-HOSTING: verify plane sam deklaruje syntetyki (system obserwuje
# samego siebie, nie tylko sprawdza innych).
# ============================================================================
set -u

VERIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=core/lib.sh
. "$VERIFY_DIR/core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== OBS-BASELINE — SYNTHETICS GATE (OBS-16) ==="

SKELETON=".skeleton.yaml"
SYNTHETICS="config/canonical/synthetics.yaml"

# ── Odczyt flagi `web` z .skeleton.yaml ────────────────────────────────────
WEB_FLAG=""
if repo_file "$SKELETON"; then
  if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" >/dev/null 2>&1; then
    WEB_FLAG="$(python3 - "$SKELETON" <<'PY' 2>/dev/null
import sys, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
print("true" if data.get("web") else "false")
PY
)"
  else
    if grep -qE '^web:[[:space:]]*true' "$SKELETON"; then
      WEB_FLAG="true"
    else
      WEB_FLAG="false"
    fi
  fi
fi

# ── Warunkowość: web:false → skip + evidence N/A ───────────────────────────
if [ "$WEB_FLAG" != "true" ]; then
  info "OBS-16 Synthetics" "SKIP — projekt nie eksponuje HTTP (web: false w $SKELETON)."
  evidence_record "verify:obs-synthetics-check:NA" "verify" "obs-synthetics-check.sh"
  verify_module_exit
fi

# ── OBS-16: syntetyki zadeklarowane (web:true) ─────────────────────────────
if repo_file "$SYNTHETICS" && grep -qE '^synthetics:' "$SYNTHETICS" \
   && grep -qE 'endpoint:' "$SYNTHETICS" \
   && grep -qE 'expected_status:' "$SYNTHETICS"; then
  pass "OBS-16 Synthetics" BLOCKING "Projekt web:true ma zadeklarowane syntetyki (endpoint + expected_status)."
else
  fail "OBS-16 Synthetics" BLOCKING "Projekt web:true NIE ma zadeklarowanych syntetyków ($SYNTHETICS)."
fi

# ── Evidence ────────────────────────────────────────────────────────────────
if verify_blocked; then
  evidence_record "verify:obs-synthetics-check:FAIL" "verify" "obs-synthetics-check.sh"
else
  evidence_record "verify:obs-synthetics-check:PASS" "verify" "obs-synthetics-check.sh"
fi

verify_module_exit

#!/usr/bin/env bash
# ============================================================================
# obs-dashboards-check.sh — OBS-BASELINE — DASHBOARDS GATE
# ============================================================================
# Universal Project Template — Repository Certification Engine
#
# OBS-BASELINE: szablon rodzi obserwowalne projekty. Ten moduł pilnuje, że
# krytyczne serwisy (tier 1-2) mają dashboardy — wizualizacje, które pozwalają
# człowiekowi zobaczyć stan serwisu w czasie rzeczywistym. Serwis bez
# dashboardu to "czarna skrzynka" — nie da się go operować.
#
# Checki:
#   OBS-15  Krytyczne serwisy (tier 1-2) mają zadeklarowany dashboard.
#
# ZASADA TEMPLATE: świeży projekt (zero kodu domenowego) ma tier: 3, więc
# dashboardy nie są obowiązkowe. Manifest dashboards.yaml jest częścią
# szablonu.
#
# SELF-HOSTING: verify plane sam deklaruje dashboardy (system obserwuje
# samego siebie, nie tylko sprawdza innych).
# ============================================================================
set -u

VERIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=core/lib.sh
. "$VERIFY_DIR/core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== OBS-BASELINE — DASHBOARDS GATE ==="

SKELETON=".skeleton.yaml"
DASHBOARDS="config/canonical/dashboards.yaml"

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

# ── Dashboardy obowiązkowe dla tier 1-2 ────────────────────────────────────
if [ "$TIER" -le 2 ]; then
  # Krytyczny serwis — dashboard WYMAGANY.
  if repo_file "$DASHBOARDS" && grep -qE '^dashboards:' "$DASHBOARDS" \
     && grep -qE 'path:' "$DASHBOARDS"; then
    pass "OBS-15 Dashboards for critical services" BLOCKING "Krytyczny serwis (tier $TIER) ma zadeklarowany dashboard."
  else
    fail "OBS-15 Dashboards for critical services" BLOCKING "Krytyczny serwis (tier $TIER) NIE ma zadeklarowanego dashboardu ($DASHBOARDS)."
  fi
else
  # Tier 3 — nieobowiązkowy. Jeśli zadeklarowany, walidujemy obecność.
  if repo_file "$DASHBOARDS" && grep -qE '^dashboards:' "$DASHBOARDS" \
     && grep -qE 'path:' "$DASHBOARDS"; then
    pass "OBS-15 Dashboards for critical services" BLOCKING "Dashboardy zadeklarowane (tier $TIER — nieobowiązkowe)."
  else
    info "OBS-15 Dashboards for critical services" "SKIP — tier $TIER nie wymaga dashboardów (obowiązkowe dla tier 1-2)."
  fi
fi

# ── Evidence ────────────────────────────────────────────────────────────────
if verify_blocked; then
  evidence_record "verify:obs-dashboards-check:FAIL" "verify" "obs-dashboards-check.sh"
else
  evidence_record "verify:obs-dashboards-check:PASS" "verify" "obs-dashboards-check.sh"
fi

verify_module_exit

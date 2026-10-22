#!/usr/bin/env bash
# ============================================================================
# obs-health-endpoints.sh — OBS-BASELINE — HEALTH ENDPOINTS GATE (OBS-10)
# ============================================================================
# Universal Project Template — Repository Certification Engine
#
# OBS-BASELINE: szablon rodzi obserwowalne projekty. Ten moduł pilnuje, że
# projekt eksponujący HTTP (web: true) ma standardowe endpointy health:
#   * /healthz  — liveness (czy proces żyje)
#   * /readyz   — readiness (czy gotowy na ruch)
#
# Checki:
#   OBS-10  Projekt web:true MUSI deklarować healthz/readyz endpoints.
#
# WARUNKOWOŚĆ: moduł czyta flagę `web` z .skeleton.yaml.
#   * web: false → SKIP + evidence N/A (projekt nie eksponuje HTTP).
#   * web: true  → sprawdza, że healthz/readyz są zadeklarowane (OBS-10).
#
# ZASADA TEMPLATE: świeży projekt (zero kodu domenowego) ma web: false,
# więc moduł robi skip. Placeholdery endpointów NIGDY nie są realnymi URL-ami
# (self-scan — sprawdzamy deklarację, nie żywotność).
#
# SELF-HOSTING: verify plane sam deklaruje health endpoints (system obserwuje
# samego siebie, nie tylko sprawdza innych).
# ============================================================================
set -u

VERIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=core/lib.sh
. "$VERIFY_DIR/core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== OBS-BASELINE — HEALTH ENDPOINTS GATE (OBS-10) ==="

SKELETON=".skeleton.yaml"

# ── Odczyt flagi `web` z .skeleton.yaml ────────────────────────────────────
# Preferujemy python3+yaml (authoritative). Fallback przez grep.
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
    # Fallback: grep flagi web: true/false.
    if grep -qE '^web:[[:space:]]*true' "$SKELETON"; then
      WEB_FLAG="true"
    else
      WEB_FLAG="false"
    fi
  fi
fi

# ── Warunkowość: web:false → skip + evidence N/A ───────────────────────────
if [ "$WEB_FLAG" != "true" ]; then
  info "OBS-10 Health endpoints" "SKIP — projekt nie eksponuje HTTP (web: false w $SKELETON)."
  evidence_record "verify:obs-health-endpoints:NA" "verify" "obs-health-endpoints.sh"
  verify_module_exit
fi

# ── OBS-10: healthz/readyz zadeklarowane (web:true) ────────────────────────
# Sprawdzamy, że projekt deklaruje healthz i readyz. Źródłem deklaracji może
# być: config/canonical/observability.yaml (sekcja health), plik endpoints,
# lub wzorzec w kodzie. Preferujemy manifest observability.yaml.
OBS10_FAIL=0
HEALTHZ_DECLARED=0
READYZ_DECLARED=0

# 1) Manifest observability.yaml — sekcja health/endpoints.
#    Dopasowujemy KLUCZE YAML (liveness:/readiness:), nie luźne stringi —
#    komentarze w manifeście mogą zawierać słowa healthz/readyz i nie mogą
#    być traktowane jako deklaracja endpointów.
if repo_file "config/canonical/observability.yaml"; then
  if grep -qE '^[[:space:]]*liveness:' "config/canonical/observability.yaml"; then
    HEALTHZ_DECLARED=1
  fi
  if grep -qE '^[[:space:]]*readiness:' "config/canonical/observability.yaml"; then
    READYZ_DECLARED=1
  fi
fi

# 2) Fallback: wzorzec w kodzie domenowym (tools/ poza tools/verify/).
if [ "$HEALTHZ_DECLARED" -eq 0 ] || [ "$READYZ_DECLARED" -eq 0 ]; then
  if repo_files --dir tools | grep -v '^tools/verify/' | xargs -r grep -lE 'healthz' 2>/dev/null | grep -q .; then
    HEALTHZ_DECLARED=1
  fi
  if repo_files --dir tools | grep -v '^tools/verify/' | xargs -r grep -lE 'readyz' 2>/dev/null | grep -q .; then
    READYZ_DECLARED=1
  fi
fi

if [ "$HEALTHZ_DECLARED" -eq 1 ] && [ "$READYZ_DECLARED" -eq 1 ]; then
  pass "OBS-10 Health endpoints" BLOCKING "Projekt deklaruje /healthz (liveness) i /readyz (readiness)."
else
  OBS10_FAIL=1
  fail "OBS-10 Health endpoints" BLOCKING "Projekt web:true NIE deklaruje kompletnych health endpoints (healthz=$HEALTHZ_DECLARED readyz=$READYZ_DECLARED)."
fi

# ── Evidence ────────────────────────────────────────────────────────────────
if verify_blocked; then
  evidence_record "verify:obs-health-endpoints:FAIL" "verify" "obs-health-endpoints.sh"
else
  evidence_record "verify:obs-health-endpoints:PASS" "verify" "obs-health-endpoints.sh"
fi

verify_module_exit

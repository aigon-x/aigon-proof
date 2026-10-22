#!/usr/bin/env bash
# ============================================================================
# obs-slo-check.sh — OBS-BASELINE — SLO GATE (OBS-14)
# ============================================================================
# Universal Project Template — Repository Certification Engine
#
# OBS-BASELINE: szablon rodzi obserwowalne projekty. Ten moduł pilnuje, że
# SLO są REALNE i OPERACYJNE:
#   * target w dozwolonym zakresie (0 < target <= 1)
#   * każdy SLO ma alert_ref (SLO bez alertu to "cel bez alarmu" = FAIL)
#   * tier z .skeleton.yaml determinuje minimalny target:
#       tier 1 → target >= 0.99, tier 2 → >= 0.95, tier 3 → >= 0.90
#
# Checki:
#   OBS-14  SLO mają target w zakresie, alert_ref, i spełniają floor tier.
#
# ZASADA TEMPLATE: detektor MUSI przechodzić na świeżym projekcie (zero kodu
# domenowego). Manifest slo.yaml jest częścią szablonu.
#
# SELF-HOSTING: verify plane sam deklaruje SLO (system obserwuje samego
# siebie, nie tylko sprawdza innych).
# ============================================================================
set -u

VERIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=core/lib.sh
. "$VERIFY_DIR/core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== OBS-BASELINE — SLO GATE (OBS-14) ==="

SLO_FILE="config/canonical/slo.yaml"
SKELETON=".skeleton.yaml"

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

# ── Minimalny target wg tier ───────────────────────────────────────────────
case "$TIER" in
  1) MIN_TARGET="0.99" ;;
  2) MIN_TARGET="0.95" ;;
  *) MIN_TARGET="0.90" ;;
esac

# ── Walidacja SLO ──────────────────────────────────────────────────────────
if repo_file "$SLO_FILE"; then
  if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" >/dev/null 2>&1; then
    PY_OUT="$(python3 - "$SLO_FILE" "$MIN_TARGET" <<'PY' 2>&1
import sys, yaml

with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)

min_target = float(sys.argv[2])
errors = []
if not isinstance(data, dict) or "slo" not in data:
    print("NO_SLO")
    sys.exit(1)

slo = data["slo"]
if not isinstance(slo, list) or len(slo) == 0:
    print("NO_SLO")
    sys.exit(1)

for s in slo:
    if not isinstance(s, dict):
        errors.append(f"slo not dict: {s}")
        continue
    service = s.get("service", "?")
    sli = s.get("sli", "?")
    name = f"{service}/{sli}"
    # OBS-14: alert_ref wymagany
    if not s.get("alert_ref"):
        errors.append(f"OBS-14 {name}: brak 'alert_ref'")
    # OBS-14: target w zakresie (0 < target <= 1)
    target = s.get("target")
    if target is None:
        errors.append(f"OBS-14 {name}: brak 'target'")
    else:
        try:
            t = float(target)
        except (TypeError, ValueError):
            errors.append(f"OBS-14 {name}: target '{target}' nie jest liczbą")
            continue
        if not (0 < t <= 1):
            errors.append(f"OBS-14 {name}: target {t} poza zakresem (0 < target <= 1)")
        # OBS-14: floor tier
        if t < min_target:
            errors.append(f"OBS-14 {name}: target {t} < floor tier ({min_target})")

if errors:
    for e in errors:
        print(e)
    sys.exit(1)
print("OK")
PY
)"
    if [ "$PY_OUT" = "OK" ]; then
      pass "OBS-14 SLO targets + alert_ref" BLOCKING "SLO mają target w zakresie, alert_ref, i spełniają floor tier ($MIN_TARGET)."
    elif [ "$PY_OUT" = "NO_SLO" ]; then
      fail "OBS-14 SLO targets + alert_ref" BLOCKING "Manifest nie zawiera SLO (slo: [])."
    else
      fail "OBS-14 SLO targets + alert_ref" BLOCKING "Naruszenia SLO (target/alert_ref/floor tier):"
      printf '%s\n' "$PY_OUT" | sed 's/^/       /'
    fi
  else
    # Fallback strukturalny: kluczowe pola muszą występować.
    if grep -qE '^slo:' "$SLO_FILE" \
       && grep -qE 'target:' "$SLO_FILE" \
       && grep -qE 'alert_ref:' "$SLO_FILE"; then
      pass "OBS-14 SLO targets + alert_ref" BLOCKING "Manifest SLO obecny (fallback strukturalny)."
    else
      fail "OBS-14 SLO targets + alert_ref" BLOCKING "Manifest SLO niekompletny (fallback strukturalny)."
    fi
  fi
else
  fail "OBS-14 SLO targets + alert_ref" BLOCKING "Brak $SLO_FILE — manifest SLO nie istnieje."
fi

# ── Evidence ────────────────────────────────────────────────────────────────
if verify_blocked; then
  evidence_record "verify:obs-slo-check:FAIL" "verify" "obs-slo-check.sh"
else
  evidence_record "verify:obs-slo-check:PASS" "verify" "obs-slo-check.sh"
fi

verify_module_exit

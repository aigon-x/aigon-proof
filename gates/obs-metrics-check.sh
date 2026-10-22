#!/usr/bin/env bash
# ============================================================================
# obs-metrics-check.sh — OBS-BASELINE — METRICS GATE (OBS-03, OBS-06)
# ============================================================================
# Universal Project Template — Repository Certification Engine
#
# OBS-BASELINE: szablon rodzi obserwowalne projekty. Ten moduł pilnuje, że
# metryki są STRUKTURALNE (manifest observability.yaml) i BEZPIECZNE
# (kontrolowana kardynalność, spójne nazewnictwo).
#
# Checki:
#   OBS-03  Metryki mają spójne nazewnictwo (konwencja <ns>_<name>_<unit>)
#           i kontrolowaną kardynalność (zakazane etykiety o wysokiej
#           kardynalności: user_id, request_id, trace_id, ...).
#   OBS-06  Każda metryka ma kompletne definicje (type, unit, description).
#           Metryka bez unit/type/description = FAIL.
#
# ZASADA TEMPLATE: detektor MUSI przechodzić na świeżym projekcie (zero kodu
# domenowego). Manifest observability.yaml jest częścią szablonu.
#
# SELF-HOSTING: verify plane sam emituje metryki (system obserwuje samego
# siebie, nie tylko sprawdza innych).
# ============================================================================
set -u

VERIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=core/lib.sh
. "$VERIFY_DIR/core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== OBS-BASELINE — METRICS GATE (OBS-03, OBS-06) ==="

OBSERVABILITY="config/canonical/observability.yaml"

# ── OBS-03/06: walidacja manifestu metryk ──────────────────────────────────
# Preferujemy pełną walidację python3+yaml (authoritative). Fallback
# strukturalny przez grep, gdy python3+yaml niedostępne.
if repo_file "$OBSERVABILITY"; then
  if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" >/dev/null 2>&1; then
    # Pełna walidacja: nazewnictwo (OBS-03), kardynalność (OBS-03),
    # kompletność definicji (OBS-06).
    PY_OUT="$(python3 - "$OBSERVABILITY" <<'PY' 2>&1
import sys, re, yaml

with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)

errors = []
if not isinstance(data, dict) or "metrics" not in data:
    print("NO_METRICS")
    sys.exit(1)

metrics = data["metrics"]
if not isinstance(metrics, list) or len(metrics) == 0:
    print("NO_METRICS")
    sys.exit(1)

# OBS-06: kompletność definicji (type, unit, description).
for m in metrics:
    if not isinstance(m, dict):
        errors.append(f"metric not dict: {m}")
        continue
    name = m.get("name", "?")
    for field in ("type", "unit", "description"):
        if not m.get(field):
            errors.append(f"OBS-06 {name}: brak '{field}'")

# OBS-03: nazewnictwo (konwencja <ns>_<name>_<unit>).
naming = data.get("naming", {})
pattern = naming.get("pattern", "^[a-z0-9_]+_[a-z0-9_]+_(total|errors|seconds|bytes|ratio|count)$")
for m in metrics:
    name = m.get("name", "")
    if not re.match(pattern, name):
        errors.append(f"OBS-03 {name}: nazwa nie pasuje do konwencji {pattern}")

# OBS-03: kardynalność (zakazane etykiety o wysokiej kardynalności).
forbidden = set(data.get("cardinality", {}).get("forbidden_labels", []))
max_labels = data.get("cardinality", {}).get("max_labels", 5)
for m in metrics:
    name = m.get("name", "?")
    labels = m.get("labels", [])
    if len(labels) > max_labels:
        errors.append(f"OBS-03 {name}: {len(labels)} etykiet > max {max_labels}")
    for lbl in labels:
        if lbl in forbidden:
            errors.append(f"OBS-03 {name}: zabroniona etykieta o wysokiej kardynalności '{lbl}'")

if errors:
    for e in errors:
        print(e)
    sys.exit(1)
print("OK")
PY
)"
    if [ "$PY_OUT" = "OK" ]; then
      pass "OBS-03 Metric naming + cardinality" BLOCKING "Metryki mają spójne nazewnictwo i kontrolowaną kardynalność."
      pass "OBS-06 Metric definitions" BLOCKING "Każda metryka ma kompletne definicje (type/unit/description)."
    elif [ "$PY_OUT" = "NO_METRICS" ]; then
      fail "OBS-03 Metric naming + cardinality" BLOCKING "Manifest nie zawiera metryk (metrics: [])."
      fail "OBS-06 Metric definitions" BLOCKING "Manifest nie zawiera metryk do walidacji."
    else
      fail "OBS-03 Metric naming + cardinality" BLOCKING "Naruszenia nazewnictwa/kardynalności:"
      printf '%s\n' "$PY_OUT" | sed 's/^/       /'
      fail "OBS-06 Metric definitions" BLOCKING "Naruszenia kompletności definicji (patrz wyżej)."
    fi
  else
    # Fallback strukturalny: kluczowe pola muszą występować.
    if grep -qE '^metrics:' "$OBSERVABILITY" \
       && grep -qE 'name:' "$OBSERVABILITY" \
       && grep -qE 'type:' "$OBSERVABILITY" \
       && grep -qE 'unit:' "$OBSERVABILITY" \
       && grep -qE 'description:' "$OBSERVABILITY"; then
      pass "OBS-03 Metric naming + cardinality" BLOCKING "Manifest metryk obecny (fallback strukturalny)."
      pass "OBS-06 Metric definitions" BLOCKING "Definicje metryk obecne (fallback strukturalny)."
    else
      fail "OBS-03 Metric naming + cardinality" BLOCKING "Manifest metryk niekompletny (fallback strukturalny)."
      fail "OBS-06 Metric definitions" BLOCKING "Definicje metryk niekompletne (fallback strukturalny)."
    fi
  fi
else
  fail "OBS-03 Metric naming + cardinality" BLOCKING "Brak $OBSERVABILITY — manifest metryk nie istnieje."
  fail "OBS-06 Metric definitions" BLOCKING "Brak $OBSERVABILITY — nie można walidować definicji."
fi

# ── Evidence ────────────────────────────────────────────────────────────────
if verify_blocked; then
  evidence_record "verify:obs-metrics-check:FAIL" "verify" "obs-metrics-check.sh"
else
  evidence_record "verify:obs-metrics-check:PASS" "verify" "obs-metrics-check.sh"
fi

verify_module_exit

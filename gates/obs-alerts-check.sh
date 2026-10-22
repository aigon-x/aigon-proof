#!/usr/bin/env bash
# ============================================================================
# obs-alerts-check.sh — OBS-BASELINE — ALERTS GATE (OBS-05, OBS-11, OBS-12)
# ============================================================================
# Universal Project Template — Repository Certification Engine
#
# OBS-BASELINE: szablon rodzi obserwowalne projekty. Ten moduł pilnuje, że
# alerty są OPERACYJNE: każdy alert ma runbook (procedura reakcji), owner
# (kto odpowiada) i severity (jak pilne). Alert bez runbooka/ownera/severity
# to "alert, który nikt nie odbierze" — gorszy niż brak alertu.
#
# Checki:
#   OBS-05  Każdy alert ma runbook_ref (alert bez runbooka = FAIL).
#   OBS-11  Każdy alert ma owner (alert bez właściciela = FAIL).
#   OBS-12  Każdy alert ma severity z dozwolonego zbioru
#           (critical | warning | info) — inna wartość = FAIL.
#
# ZASADA TEMPLATE: detektor MUSI przechodzić na świeżym projekcie (zero kodu
# domenowego). Szablon alertów (config/canonical/alerts/_template.yaml) jest
# częścią szablonu i przechodzi wszystkie checki.
#
# SELF-HOSTING: verify plane sam deklaruje alerty (system obserwuje samego
# siebie, nie tylko sprawdza innych).
# ============================================================================
set -u

VERIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=core/lib.sh
. "$VERIFY_DIR/core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== OBS-BASELINE — ALERTS GATE (OBS-05, OBS-11, OBS-12) ==="

ALERTS_DIR="config/canonical/alerts"

# ── Zbiór dozwolonych severity (OBS-12) ────────────────────────────────────
ALLOWED_SEVERITY="critical warning info"

# ── Zbierz pliki alertów ───────────────────────────────────────────────────
# Akceptujemy: pojedynczy plik z listą `alerts:` (np. _template.yaml) oraz
# pliki YAML w katalogu alerts/. Ignorujemy pliki nie-YAML.
ALERT_FILES="$(repo_files --dir "$ALERTS_DIR" --name '\.ya?ml$')"

if [ -z "$ALERT_FILES" ]; then
  fail "OBS-05 Alerts have runbook" BLOCKING "Brak plików alertów w $ALERTS_DIR — nie ma alertów do walidacji."
  fail "OBS-11 Alerts have owner" BLOCKING "Brak plików alertów w $ALERTS_DIR — nie ma alertów do walidacji."
  fail "OBS-12 Alerts have severity" BLOCKING "Brak plików alertów w $ALERTS_DIR — nie ma alertów do walidacji."
  evidence_record "verify:obs-alerts-check:FAIL" "verify" "obs-alerts-check.sh"
  verify_module_exit
fi

# ── Walidacja alertów ──────────────────────────────────────────────────────
# Preferujemy pełną walidację python3+yaml (authoritative). Fallback
# strukturalny przez grep, gdy python3+yaml niedostępne.
if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" >/dev/null 2>&1; then
  PY_OUT="$(python3 - "$ALERTS_DIR" <<'PY' 2>&1
import sys, os, re, yaml

alerts_dir = sys.argv[1]
allowed = {"critical", "warning", "info"}
errors = []
found = 0

for root, dirs, files in os.walk(alerts_dir):
    for fn in sorted(files):
        if not fn.endswith((".yaml", ".yml")):
            continue
        path = os.path.join(root, fn)
        try:
            with open(path) as f:
                data = yaml.safe_load(f)
        except Exception as e:
            errors.append(f"{path}: błąd YAML: {e}")
            continue
        if not isinstance(data, dict):
            continue
        alerts = data.get("alerts", [])
        if not isinstance(alerts, list):
            continue
        for a in alerts:
            if not isinstance(a, dict):
                errors.append(f"{path}: alert nie jest mapą: {a}")
                continue
            found += 1
            name = a.get("name", "?")
            # OBS-05: runbook_ref wymagany
            if not a.get("runbook_ref"):
                errors.append(f"OBS-05 {path} [{name}]: brak 'runbook_ref'")
            # OBS-11: owner wymagany
            if not a.get("owner"):
                errors.append(f"OBS-11 {path} [{name}]: brak 'owner'")
            # OBS-12: severity z dozwolonego zbioru
            sev = a.get("severity")
            if not sev:
                errors.append(f"OBS-12 {path} [{name}]: brak 'severity'")
            elif sev not in allowed:
                errors.append(f"OBS-12 {path} [{name}]: severity '{sev}' poza dozwolonym zbiorem {sorted(allowed)}")

if found == 0:
    print("NO_ALERTS")
    sys.exit(1)

if errors:
    for e in errors:
        print(e)
    sys.exit(1)
print("OK")
PY
)"
  if [ "$PY_OUT" = "OK" ]; then
    pass "OBS-05 Alerts have runbook" BLOCKING "Każdy alert ma runbook_ref."
    pass "OBS-11 Alerts have owner" BLOCKING "Każdy alert ma owner."
    pass "OBS-12 Alerts have severity" BLOCKING "Każdy alert ma severity z dozwolonego zbioru (critical|warning|info)."
  elif [ "$PY_OUT" = "NO_ALERTS" ]; then
    fail "OBS-05 Alerts have runbook" BLOCKING "Nie znaleziono żadnych alertów w $ALERTS_DIR."
    fail "OBS-11 Alerts have owner" BLOCKING "Nie znaleziono żadnych alertów w $ALERTS_DIR."
    fail "OBS-12 Alerts have severity" BLOCKING "Nie znaleziono żadnych alertów w $ALERTS_DIR."
  else
    fail "OBS-05 Alerts have runbook" BLOCKING "Naruszenia runbook_ref (patrz niżej)."
    fail "OBS-11 Alerts have owner" BLOCKING "Naruszenia owner (patrz niżej)."
    fail "OBS-12 Alerts have severity" BLOCKING "Naruszenia severity (patrz niżej)."
    printf '%s\n' "$PY_OUT" | sed 's/^/       /'
  fi
else
  # Fallback strukturalny: kluczowe pola muszą występować w plikach alertów.
  if grep -rqE 'runbook_ref:' "$ALERTS_DIR" \
     && grep -rqE 'owner:' "$ALERTS_DIR" \
     && grep -rqE 'severity:' "$ALERTS_DIR"; then
    pass "OBS-05 Alerts have runbook" BLOCKING "Alerty mają runbook_ref (fallback strukturalny)."
    pass "OBS-11 Alerts have owner" BLOCKING "Alerty mają owner (fallback strukturalny)."
    pass "OBS-12 Alerts have severity" BLOCKING "Alerty mają severity (fallback strukturalny)."
  else
    fail "OBS-05 Alerts have runbook" BLOCKING "Brak runbook_ref w alertach (fallback strukturalny)."
    fail "OBS-11 Alerts have owner" BLOCKING "Brak owner w alertach (fallback strukturalny)."
    fail "OBS-12 Alerts have severity" BLOCKING "Brak severity w alertach (fallback strukturalny)."
  fi
fi

# ── Evidence ────────────────────────────────────────────────────────────────
if verify_blocked; then
  evidence_record "verify:obs-alerts-check:FAIL" "verify" "obs-alerts-check.sh"
else
  evidence_record "verify:obs-alerts-check:PASS" "verify" "obs-alerts-check.sh"
fi

verify_module_exit

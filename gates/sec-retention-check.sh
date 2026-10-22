#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# security/sec-retention-check.sh — Universal Project Template — Repository Certification Engine
# Moduł: SEC-BASELINE — RETENTION POLICY
# Weryfikuje, że istnieje polityka retencji sekretów/logów i że jest zgodna
# z wymogami (np. logi >= 90 dni).
#
# SEC-BASELINE: ten moduł rodzi się w KAŻDYM projekcie utworzonym z template'u.
# ZASADA TEMPLATE: skrypt MUSI przechodzić na świeżym projekcie. Placeholdery
# w config/canonical/retention.yaml NIE są realnymi danymi operacyjnymi.
#
# Checki:
#   SEC-RET-01  Retention policy exists
#   SEC-RET-02  Retention meets requirements (e.g. logs >= 90 days)
#
# Delegacja: czyta config/canonical/retention.yaml (YAML). Parsowanie przez
# awk (fallback, bez zależności od yq).
# ─────────────────────────────────────────────────────────────
set -u

# shellcheck source=../core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== SEC-BASELINE — RETENTION POLICY (SEC-RET-01..02) ==="

POLICY="$ROOT/config/canonical/retention.yaml"

# ── SEC-RET-01 Retention policy exists ──────────────────────
if [ -f "$POLICY" ]; then
  pass "SEC-RET-01 Retention policy exists" BLOCKING "Polityka retencji: $POLICY"
else
  fail "SEC-RET-01 Retention policy exists" BLOCKING "Brak polityki retencji: $POLICY"
  fail "SEC-RET-02 Retention meets requirements" BLOCKING "Brak polityki retencji do weryfikacji."
  evidence_record "verify:sec-retention-check:FAIL" "verify" "security/sec-retention-check.sh"
  verify_module_exit
fi

# ── Parsowanie kategorii retencji (name|retention_days|required_min_days) ──
parse_policy() {
  awk '
    /^  - name:/ {
      if (name != "") print name "|" ret "|" req
      name=$3; ret=""; req=""
      next
    }
    /^    retention_days:/ { ret=$2; next }
    /^    required_min_days:/ { req=$2; next }
    END { if (name != "") print name "|" ret "|" req }
  ' "$POLICY"
}

POLICY_ENTRIES="$(parse_policy)"
if [ -z "$POLICY_ENTRIES" ]; then
  fail "SEC-RET-02 Retention meets requirements" BLOCKING "Polityka retencji nie zawiera żadnych kategorii."
  evidence_record "verify:sec-retention-check:FAIL" "verify" "security/sec-retention-check.sh"
  verify_module_exit
fi

# ── SEC-RET-02 Retention meets requirements ─────────────────
# Każda kategoria: retention_days >= required_min_days.
# Dodatkowo: logi aplikacyjne (application_logs) muszą mieć >= 90 dni.
VIOLATIONS=""
while IFS='|' read -r name ret req; do
  [ -z "$name" ] && continue
  if [ -z "$ret" ] || [ -z "$req" ]; then
    VIOLATIONS="$VIOLATIONS $name(missing-days)"
    continue
  fi
  if [ "$ret" -lt "$req" ] 2>/dev/null; then
    VIOLATIONS="$VIOLATIONS $name($ret<$req)"
  fi
done <<< "$POLICY_ENTRIES"

# Wymóg logów >= 90 dni (jawny, fail-closed).
APP_LOGS_OK=1
APP_LOGS_DAYS="$(printf '%s\n' "$POLICY_ENTRIES" | awk -F'|' '$1=="application_logs" {print $2}')"
if [ -z "$APP_LOGS_DAYS" ]; then
  APP_LOGS_OK=0
  VIOLATIONS="$VIOLATIONS application_logs(missing)"
elif [ "$APP_LOGS_DAYS" -lt 90 ] 2>/dev/null; then
  APP_LOGS_OK=0
  VIOLATIONS="$VIOLATIONS application_logs($APP_LOGS_DAYS<90)"
fi

if [ -z "$VIOLATIONS" ]; then
  pass "SEC-RET-02 Retention meets requirements" BLOCKING "Wszystkie kategorie retencji spełniają wymogi (w tym logi >= 90 dni)."
else
  fail "SEC-RET-02 Retention meets requirements" BLOCKING "Naruszenia retencji:$(printf '%s' "$VIOLATIONS")"
fi

# ── Evidence ─────────────────────────────────────────────────
if verify_blocked; then
  evidence_record "verify:sec-retention-check:FAIL" "verify" "security/sec-retention-check.sh"
else
  evidence_record "verify:sec-retention-check:PASS" "verify" "security/sec-retention-check.sh"
fi

verify_module_exit

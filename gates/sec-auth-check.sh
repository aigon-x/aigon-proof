#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# security/sec-auth-check.sh — Universal Project Template — Repository Certification Engine
# Moduł: SEC-BASELINE — AUTHORIZATION
# Weryfikuje, że mechanizmy autoryzacji są zdefiniowane: definicja autoryzacji,
# role i uprawnienia, oraz SoD (separation of duties) — autor ≠ approver ≠ deployer.
#
# SEC-BASELINE: ten moduł rodzi się w KAŻDYM projekcie utworzonym z template'u.
# ZASADA TEMPLATE: skrypt MUSI przechodzić na świeżym projekcie. Placeholdery
# w config/canonical/auth.yaml NIE są realnymi danymi operacyjnymi.
#
# Checki:
#   SEC-AUTH-01  Authorization definition exists
#   SEC-AUTH-02  Roles and permissions are defined
#   SEC-AUTH-03  Separation of duties (SoD) is defined — author ≠ approver ≠ deployer
#
# Delegacja: czyta config/canonical/auth.yaml (YAML). Parsowanie przez awk
# (fallback, bez zależności od yq).
# ─────────────────────────────────────────────────────────────
set -u

# shellcheck source=../core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== SEC-BASELINE — AUTHORIZATION (SEC-AUTH-01..03) ==="

AUTH="$ROOT/config/canonical/auth.yaml"

# ── SEC-AUTH-01 Authorization definition exists ─────────────
if [ -f "$AUTH" ]; then
  pass "SEC-AUTH-01 Authorization definition exists" BLOCKING "Definicja autoryzacji: $AUTH"
else
  fail "SEC-AUTH-01 Authorization definition exists" BLOCKING "Brak definicji autoryzacji: $AUTH"
  fail "SEC-AUTH-02 Roles and permissions defined" BLOCKING "Brak definicji autoryzacji."
  fail "SEC-AUTH-03 Separation of duties defined" BLOCKING "Brak definicji autoryzacji."
  evidence_record "verify:sec-auth-check:FAIL" "verify" "security/sec-auth-check.sh"
  verify_module_exit
fi

# ── SEC-AUTH-02 Roles and permissions are defined ───────────
# Wymagamy co najmniej jednej roli z uprawnieniami.
ROLE_COUNT="$(awk '/^  - name:/{c++} END{print c+0}' "$AUTH")"
PERM_COUNT="$(awk '/permissions:/{c++} END{print c+0}' "$AUTH")"
if [ "$ROLE_COUNT" -ge 1 ] && [ "$PERM_COUNT" -ge 1 ]; then
  pass "SEC-AUTH-02 Roles and permissions defined" BLOCKING "Zdefiniowano $ROLE_COUNT ról z uprawnieniami."
else
  fail "SEC-AUTH-02 Roles and permissions defined" BLOCKING "Brak ról ($ROLE_COUNT) lub uprawnień ($PERM_COUNT) w definicji autoryzacji."
fi

# ── SEC-AUTH-03 Separation of duties (SoD) is defined ───────
# SoD: autor ≠ approver ≠ deployer. Wymagamy sekcji separation_of_duties
# z enabled: true oraz reguł rozłączających role.
SOD_ENABLED="$(awk '/^separation_of_duties:/{f=1} f&&/enabled:/{print $2; exit}' "$AUTH")"
SOD_RULES="$(awk '/^separation_of_duties:/{f=1} f&&/^    - name:/{c++} END{print c+0}' "$AUTH")"

# Sprawdź, czy reguły faktycznie rozłączają role (disjoint_roles).
SOD_DISJOINT="$(awk '/disjoint_roles:/{c++} END{print c+0}' "$AUTH")"

if [ "$SOD_ENABLED" = "true" ] && [ "$SOD_RULES" -ge 1 ] && [ "$SOD_DISJOINT" -ge 1 ]; then
  pass "SEC-AUTH-03 Separation of duties defined" BLOCKING "SoD włączone ($SOD_RULES reguł) — autor ≠ approver ≠ deployer."
else
  fail "SEC-AUTH-03 Separation of duties defined" BLOCKING "SoD niekompletne: enabled=$SOD_ENABLED, reguły=$SOD_RULES, disjoint=$SOD_DISJOINT."
fi

# ── Evidence ─────────────────────────────────────────────────
if verify_blocked; then
  evidence_record "verify:sec-auth-check:FAIL" "verify" "security/sec-auth-check.sh"
else
  evidence_record "verify:sec-auth-check:PASS" "verify" "security/sec-auth-check.sh"
fi

verify_module_exit

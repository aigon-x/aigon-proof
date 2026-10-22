#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# security/sec-web-check.sh — Universal Project Template — Repository Certification Engine
# Moduł: SEC-BASELINE — WEB SECURITY
# Weryfikuje bezpieczeństwo web: nagłówki bezpieczeństwa i wymóg TLS.
#
# SEC-BASELINE: ten moduł rodzi się w KAŻDYM projekcie utworzonym z template'u.
# ZASADA TEMPLATE: skrypt MUSI przechodzić na świeżym projekcie. Placeholdery
# w config/canonical/web-security.yaml NIE są realną konfiguracją serwera.
#
# Checki:
#   SEC-WEB-01  Security headers are defined
#   SEC-WEB-02  TLS is required
#
# Delegacja: czyta config/canonical/web-security.yaml (YAML). Parsowanie przez
# awk (fallback, bez zależności od yq).
# ─────────────────────────────────────────────────────────────
set -u

# shellcheck source=../core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== SEC-BASELINE — WEB SECURITY (SEC-WEB-01..02) ==="

WEB="$ROOT/config/canonical/web-security.yaml"

# ── SEC-WEB-01 Security headers are defined ─────────────────
if [ -f "$WEB" ]; then
  HEADERS_ENABLED="$(awk '/^security_headers:/{f=1} f&&/enabled:/{print $2; exit}' "$WEB")"
  HEADER_COUNT="$(awk '/^    - name:/{c++} END{print c+0}' "$WEB")"
  if [ "$HEADERS_ENABLED" = "true" ] && [ "$HEADER_COUNT" -ge 1 ]; then
    pass "SEC-WEB-01 Security headers defined" BLOCKING "Zdefiniowano $HEADER_COUNT nagłówków bezpieczeństwa."
  else
    fail "SEC-WEB-01 Security headers defined" BLOCKING "Nagłówki bezpieczeństwa niekompletne: enabled=$HEADERS_ENABLED, liczba=$HEADER_COUNT."
  fi
else
  fail "SEC-WEB-01 Security headers defined" BLOCKING "Brak definicji bezpieczeństwa web: $WEB"
  fail "SEC-WEB-02 TLS required" BLOCKING "Brak definicji bezpieczeństwa web: $WEB"
  evidence_record "verify:sec-web-check:FAIL" "verify" "security/sec-web-check.sh"
  verify_module_exit
fi

# ── SEC-WEB-02 TLS is required ──────────────────────────────
TLS_REQUIRED="$(awk '/^tls:/{f=1} f&&/required:/{print $2; exit}' "$WEB")"
TLS_MIN="$(awk '/^tls:/{f=1} f&&/min_version:/{print $2; exit}' "$WEB")"
if [ "$TLS_REQUIRED" = "true" ]; then
  pass "SEC-WEB-02 TLS required" BLOCKING "TLS wymagany (min: ${TLS_MIN:-nieokreślony})."
else
  fail "SEC-WEB-02 TLS required" BLOCKING "TLS nie jest wymagany (required=$TLS_REQUIRED)."
fi

# ── Evidence ─────────────────────────────────────────────────
if verify_blocked; then
  evidence_record "verify:sec-web-check:FAIL" "verify" "security/sec-web-check.sh"
else
  evidence_record "verify:sec-web-check:PASS" "verify" "security/sec-web-check.sh"
fi

verify_module_exit

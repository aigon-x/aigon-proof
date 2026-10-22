#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# security/sec-credential-registry.sh — Universal Project Template — Repository Certification Engine
# Moduł: SEC-BASELINE — CREDENTIAL REGISTRY
# Weryfikuje, że istnieje rejestr poświadczeń (credential registry) i że każdy
# wpis ma wymagane pola: nazwa, właściciel, środowisko, data rotacji, status.
#
# SEC-BASELINE: ten moduł rodzi się w KAŻDYM projekcie utworzonym z template'u.
# ZASADA TEMPLATE: skrypt MUSI przechodzić na świeżym projekcie (jeszcze bez
# kodu domenowego). Placeholdery w config/canonical/credentials.yaml NIE są
# realnymi sekretami. Self-scan na samym template musi dawać PASS.
#
# Checki:
#   SEC-CR-01  Credential registry exists
#   SEC-CR-02  Every entry has an owner
#   SEC-CR-03  Every entry has a rotation date
#   SEC-CR-04  Every entry has a status (active/rotating/revoked)
#
# Delegacja: czyta config/canonical/credentials.yaml (YAML). Parsowanie przez
# awk (fallback, bez zależności od yq) — spójne z gen-profiles.sh.
# ─────────────────────────────────────────────────────────────
set -u

# shellcheck source=../core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== SEC-BASELINE — CREDENTIAL REGISTRY (SEC-CR-01..04) ==="

REGISTRY="$ROOT/config/canonical/credentials.yaml"

# ── SEC-CR-01 Credential registry exists ────────────────────
if [ -f "$REGISTRY" ]; then
  pass "SEC-CR-01 Credential registry exists" BLOCKING "Rejestr poświadczeń: $REGISTRY"
else
  fail "SEC-CR-01 Credential registry exists" BLOCKING "Brak rejestru poświadczeń: $REGISTRY"
  # Fail-closed: bez rejestru nie ma czego sprawdzać dalej.
  evidence_record "verify:sec-credential-registry:FAIL" "verify" "security/sec-credential-registry.sh"
  verify_module_exit
fi

# ── Parsowanie wpisów rejestru ──────────────────────────────
# Wyciągamy bloki "- name:" i ich pola (owner, environment, rotation_date,
# status). awk fallback — bez zależności od yq.
# Wynik: linie "name|owner|environment|rotation_date|status" per wpis.
parse_entries() {
  awk '
    /^  - name:/ {
      # nowy wpis — zapamiętaj poprzedni
      if (name != "") print name "|" owner "|" env "|" rot "|" status
      name=$3; owner=""; env=""; rot=""; status=""
      next
    }
    /^    owner:/ { owner=$2; next }
    /^    environment:/ { env=$2; next }
    /^    rotation_date:/ { rot=$2; gsub(/"/, "", rot); next }
    /^    status:/ { status=$2; next }
    END { if (name != "") print name "|" owner "|" env "|" rot "|" status }
  ' "$REGISTRY"
}

ENTRIES="$(parse_entries)"

# Liczba wpisów (fail-closed: rejestr bez wpisów = problem).
ENTRY_COUNT="$(printf '%s\n' "$ENTRIES" | grep -c '|' || true)"
if [ -z "$ENTRIES" ] || [ "$ENTRY_COUNT" -eq 0 ]; then
  fail "SEC-CR-02 Every entry has an owner" BLOCKING "Rejestr nie zawiera żadnych wpisów poświadczeń."
  fail "SEC-CR-03 Every entry has a rotation date" BLOCKING "Rejestr nie zawiera żadnych wpisów poświadczeń."
  fail "SEC-CR-04 Every entry has a status" BLOCKING "Rejestr nie zawiera żadnych wpisów poświadczeń."
  evidence_record "verify:sec-credential-registry:FAIL" "verify" "security/sec-credential-registry.sh"
  verify_module_exit
fi

# ── SEC-CR-02 Every entry has an owner ──────────────────────
MISSING_OWNER="$(printf '%s\n' "$ENTRIES" | awk -F'|' '$2=="" {print $1}')"
if [ -z "$MISSING_OWNER" ]; then
  pass "SEC-CR-02 Every entry has an owner" BLOCKING "Wszystkie $ENTRY_COUNT wpisy mają właściciela."
else
  fail "SEC-CR-02 Every entry has an owner" BLOCKING "Wpisy bez właściciela: $(printf '%s' "$MISSING_OWNER" | tr '\n' ' ')"
fi

# ── SEC-CR-03 Every entry has a rotation date ───────────────
MISSING_ROT="$(printf '%s\n' "$ENTRIES" | awk -F'|' '$4=="" {print $1}')"
if [ -z "$MISSING_ROT" ]; then
  pass "SEC-CR-03 Every entry has a rotation date" BLOCKING "Wszystkie $ENTRY_COUNT wpisy mają datę rotacji."
else
  fail "SEC-CR-03 Every entry has a rotation date" BLOCKING "Wpisy bez daty rotacji: $(printf '%s' "$MISSING_ROT" | tr '\n' ' ')"
fi

# ── SEC-CR-04 Every entry has a status (active/rotating/revoked) ──
BAD_STATUS="$(printf '%s\n' "$ENTRIES" | awk -F'|' '$5!="active" && $5!="rotating" && $5!="revoked" {print $1 " (" $5 ")"}')"
if [ -z "$BAD_STATUS" ]; then
  pass "SEC-CR-04 Every entry has a status" BLOCKING "Wszystkie $ENTRY_COUNT wpisy mają poprawny status (active/rotating/revoked)."
else
  fail "SEC-CR-04 Every entry has a status" BLOCKING "Wpisy z niepoprawnym statusem: $(printf '%s' "$BAD_STATUS" | tr '\n' ' ')"
fi

# ── Evidence ─────────────────────────────────────────────────
if verify_blocked; then
  evidence_record "verify:sec-credential-registry:FAIL" "verify" "security/sec-credential-registry.sh"
else
  evidence_record "verify:sec-credential-registry:PASS" "verify" "security/sec-credential-registry.sh"
fi

verify_module_exit

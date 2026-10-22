#!/usr/bin/env bash
# ============================================================================
# obs-logging-check.sh — OBS-BASELINE — LOGGING GATE (OBS-01, OBS-02)
# ============================================================================
# Universal Project Template — Repository Certification Engine
#
# OBS-BASELINE: szablon rodzi obserwowalne projekty. Ten moduł pilnuje, że
# logowanie jest STRUKTURALNE (JSON lines przez lib/log.sh) i BEZPIECZNE
# (scrubbing PII/sektetów).
#
# Checki:
#   OBS-01  Zakazane wzorce logowania (echo/printf poza lib/log.sh,
#           console.log, print() bez struktury) w tools/ → FAIL
#   OBS-02  TEST KANARKOWY (negative): emisja testowego PII przez lib/log.sh
#           → output NIE może zawierać kanarka w czystej postaci.
#           Kanarek przeszedł = scrubbing to placebo = FAIL.
#   OBS-01b Każda emisja ma level + ts + msg (walidacja JSON na przykładowym
#           wywołaniu).
#
# ZASADA TEMPLATE: detektor MUSI przechodzić na świeżym projekcie (zero kodu
# domenowego). Test kanarkowy działa lokalnie (airgap-safe).
#
# SELF-HOSTING: verify plane sam używa lib/log.sh (system obserwuje samego
# siebie, nie tylko sprawdza innych).
# ============================================================================
set -u

VERIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=core/lib.sh
. "$VERIFY_DIR/core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== OBS-BASELINE — LOGGING GATE (OBS-01, OBS-02) ==="

LOG_SH="$ROOT/lib/log.sh"

# ── OBS-01: zakazane wzorce logowania ───────────────────────────────────────
# Skanuje git-tracked pliki w KODZIE DOMENOWYM szkieletu (tools/scripts/)
# pod kątem bezpośredniego logowania poza lib/log.sh.
# Dozwolone: log_info/log_warn/log_error (z lib).
# Zakazane: echo/printf z treścią logową, console.log, print() bez struktury.
#
# UWAGA: skan obejmuje WYŁĄCZNIE tools/scripts/ (kod domenowy szkieletu).
# Infrastruktura narzędziowa (tools/automation, tools/scaffold, tools/config,
# tools/verify, ...) jest WYŁĄCZONA — jej echo/printf/print() to FUNKCJONALNY
# OUTPUT CLI (tabele, dane, fingerprinty), nie ad-hoc logging. OBS-01 dotyczy
# kodu domenowego, nie infrastruktury.
# ZASADA TEMPLATE: detektor MUSI przechodzić na świeżym projekcie.
OBS01_FAIL=0
if [ -f "$LOG_SH" ]; then
  # Zakazane wzorce w kodzie domenowym szkieletu (tools/scripts/).
  # echo/printf z treścią logową (nie komentarzem) — heurystyka: linia
  # zawiera echo/printf ORAZ nie jest komentarzem.
  if repo_files --dir tools/scripts | xargs -r grep -nE '^\s*(echo|printf)\s+["'"'"']' 2>/dev/null | grep -vE '^\s*#' | grep -q .; then
    OBS01_FAIL=1
    fail "OBS-01 No ad-hoc logging" BLOCKING "Wykryto bezpośrednie echo/printf z treścią w kodzie domenowym (poza lib/log.sh)."
  else
    pass "OBS-01 No ad-hoc logging" BLOCKING "Brak bezpośredniego logowania poza lib/log.sh w kodzie domenowym."
  fi
  # console.log / print() (języki wysokopoziomowe) w kodzie domenowym.
  if repo_files --dir tools/scripts | xargs -r grep -nE 'console\.log|print\(' 2>/dev/null | grep -q .; then
    OBS01_FAIL=1
    fail "OBS-01 No ad-hoc logging" BLOCKING "Wykryto console.log/print() w kodzie domenowym (poza lib/log.sh)."
  else
    pass "OBS-01 No ad-hoc logging" BLOCKING "Brak console.log/print() w kodzie domenowym."
  fi
else
  fail "OBS-01 No ad-hoc logging" BLOCKING "Brak lib/log.sh — jedyny dozwolony kanał logowania nie istnieje."
  OBS01_FAIL=1
fi

# ── OBS-02: test kanarkowy scrubbingu (negative) ────────────────────────────
# Emitujemy przez lib/log.sh string-kanarek (testowy email + testowy token).
# Output NIE może zawierać kanarka w czystej postaci → scrubbing działa = PASS.
# Kanarek przeszedł = scrubbing to placebo = FAIL.
OBS02_FAIL=0
if [ -f "$LOG_SH" ]; then
  # Kanarek: oczywiście fałszywe, ale jednoznacznie wykrywalne wartości.
  CANARY_EMAIL="canary-obs02@example.com"
  CANARY_TOKEN="sk-canary-obs02-1234567890abcdef"
  # Emisja przez lib/log.sh (na stderr).
  CANARY_OUT="$(LOG_SERVICE=canary bash -c '. "$0"; log_error "user=$CANARY_EMAIL token=$CANARY_TOKEN"' "$LOG_SH" 2>&1)"
  # Sprawdź, czy kanarek pojawił się w czystej postaci.
  if printf '%s' "$CANARY_OUT" | grep -qF "$CANARY_EMAIL"; then
    OBS02_FAIL=1
    fail "OBS-02 PII scrubbing" BLOCKING "Kanarek email przeszedł przez scrubbing — OBS-02 to placebo."
  elif printf '%s' "$CANARY_OUT" | grep -qF "$CANARY_TOKEN"; then
    OBS02_FAIL=1
    fail "OBS-02 PII scrubbing" BLOCKING "Kanarek token przeszedł przez scrubbing — OBS-02 to placebo."
  else
    pass "OBS-02 PII scrubbing" BLOCKING "Scrubbing zamaskował kanarek (email + token) — OBS-02 działa."
  fi
else
  fail "OBS-02 PII scrubbing" BLOCKING "Brak lib/log.sh — nie można przetestować scrubbingu."
  OBS02_FAIL=1
fi

# ── OBS-01b: walidacja struktury JSON (level + ts + msg) ────────────────────
# Każda emisja ma level + ts + msg. Walidujemy na przykładowym wywołaniu.
OBS01B_FAIL=0
if [ -f "$LOG_SH" ]; then
  SAMPLE_OUT="$(LOG_SERVICE=canary bash -c '. "$0"; log_info "hello world"' "$LOG_SH" 2>&1)"
  if printf '%s' "$SAMPLE_OUT" | grep -qE '"level":"info"' \
     && printf '%s' "$SAMPLE_OUT" | grep -qE '"ts":"[0-9]{4}-[0-9]{2}-[0-9]{2}T' \
     && printf '%s' "$SAMPLE_OUT" | grep -qE '"msg":"hello world"'; then
    pass "OBS-01b Structured JSON logging" BLOCKING "Emisja ma level + ts + msg (JSON line)."
  else
    OBS01B_FAIL=1
    fail "OBS-01b Structured JSON logging" BLOCKING "Emisja NIE ma kompletnej struktury JSON (level/ts/msg)."
  fi
else
  fail "OBS-01b Structured JSON logging" BLOCKING "Brak lib/log.sh — nie można walidować struktury."
  OBS01B_FAIL=1
fi

# ── Evidence ────────────────────────────────────────────────────────────────
if verify_blocked; then
  evidence_record "verify:obs-logging-check:FAIL" "verify" "obs-logging-check.sh"
else
  evidence_record "verify:obs-logging-check:PASS" "verify" "obs-logging-check.sh"
fi

verify_module_exit

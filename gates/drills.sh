#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# security/drills.sh — Universal Project Template — Repository Certification Engine
# Moduł: SECURITY — SEC-DEPLOY FIRE DRILLS
# Pipeline fire drills security (fail-closed) nad katalogiem wtrysków.
#
# Pipeline (6 faz, fail-closed):
#   PRE-FLIGHT  — katalog drills/ istnieje i ma 4 podkatalogi domen
#   INJECT      — każda domena ma plik wtrysku (README.md)
#   DETECT      — każda domena ma skrypt detekcji (README.md)
#   WALIDACJA   — każda domena ma zdefiniowany OCZEKIWANY WYNIK
#   EVIDENCE    — zapis evidence dla każdej domeny (4 rekordy)
#   DESTROY     — każda domena ma sekcję DESTROY (wtryski tymczasowe)
#
# Checki:
#   SEC-D-00  Pipeline integrity (wszystkie 6 faz wykonane poprawnie)
#   SEC-D-01  Detection drills (README z OCZEKIWANY WYNIK + DESTROY)
#   SEC-A-01  Authorization drills (README z OCZEKIWANY WYNIK + DESTROY)
#   SEC-R-01  Recovery drills (README z OCZEKIWANY WYNIK + DESTROY)
#   SEC-C-01  Confidentiality drills (README z OCZEKIWANY WYNIK + DESTROY)
# ─────────────────────────────────────────────────────────────
set -u

# shellcheck source=../core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

# Katalog wtrysków (względem root repo — moduł operuje na repo, w którym
# jest uruchamiany, więc testy izolowane mogą podmienić katalog drills/).
DRILLS_DIR="$ROOT/tools/verify/security/drills"

say "=== SECURITY — SEC-DEPLOY FIRE DRILLS ==="

# ── Domeny (jawnie konfigurowalne) ──────────────────────────
# Każda domena: <nazwa> <check-id> <opis>
DOMAINS=(
  "detection SEC-D-01 Detection drills"
  "authorization SEC-A-01 Authorization drills"
  "recovery SEC-R-01 Recovery drills"
  "confidentiality SEC-C-01 Confidentiality drills"
)

# ── Stan pipeline'u (fail-closed) ───────────────────────────
PIPELINE_OK=1   # 1 = OK, 0 = coś się nie powiodło

# ── Faza 1: PRE-FLIGHT ──────────────────────────────────────
# Katalog drills/ musi istnieć i mieć 4 podkatalogi domen.
if [ ! -d "$DRILLS_DIR" ]; then
  fail "SEC-D-00 Pipeline integrity" BLOCKING "PRE-FLIGHT: brak katalogu drills/: $DRILLS_DIR (fail-closed)"
  PIPELINE_OK=0
else
  for entry in "${DOMAINS[@]}"; do
    set -- $entry
    local_domain="$1"
    if [ ! -d "$DRILLS_DIR/$local_domain" ]; then
      fail "SEC-D-00 Pipeline integrity" BLOCKING "PRE-FLIGHT: brak podkatalogu domeny: $local_domain (fail-closed)"
      PIPELINE_OK=0
    fi
  done
fi

# ── Faza 2: INJECT ──────────────────────────────────────────
# Każda domena musi mieć plik wtrysku (README.md).
for entry in "${DOMAINS[@]}"; do
  set -- $entry
  local_domain="$1"
  if [ ! -f "$DRILLS_DIR/$local_domain/README.md" ]; then
    fail "SEC-D-00 Pipeline integrity" BLOCKING "INJECT: domena $local_domain nie ma pliku wtrysku README.md (fail-closed)"
    PIPELINE_OK=0
  fi
done

# ── Faza 3: DETECT ──────────────────────────────────────────
# Każda domena musi mieć skrypt detekcji (README.md).
for entry in "${DOMAINS[@]}"; do
  set -- $entry
  local_domain="$1"
  if [ ! -f "$DRILLS_DIR/$local_domain/README.md" ]; then
    fail "SEC-D-00 Pipeline integrity" BLOCKING "DETECT: domena $local_domain nie ma skryptu detekcji README.md (fail-closed)"
    PIPELINE_OK=0
  fi
done

# ── Faza 4: WALIDACJA ───────────────────────────────────────
# Każda domena musi mieć zdefiniowany OCZEKIWANY WYNIK w README.md.
for entry in "${DOMAINS[@]}"; do
  set -- $entry
  local_domain="$1"
  if ! grep -q "OCZEKIWANY WYNIK" "$DRILLS_DIR/$local_domain/README.md" 2>/dev/null; then
    fail "SEC-D-00 Pipeline integrity" BLOCKING "WALIDACJA: domena $local_domain nie ma sekcji OCZEKIWANY WYNIK (fail-closed)"
    PIPELINE_OK=0
  fi
done

# ── Faza 5: EVIDENCE ────────────────────────────────────────
# Zapis evidence dla każdej domeny (4 rekordy).
for entry in "${DOMAINS[@]}"; do
  set -- $entry
  local_domain="$1"
  evidence_record "verify:security-drills:$local_domain:drill" "verify" "security/drills/$local_domain"
done

# ── Faza 6: DESTROY ─────────────────────────────────────────
# Każda domena musi mieć sekcję DESTROY (wtryski tymczasowe).
for entry in "${DOMAINS[@]}"; do
  set -- $entry
  local_domain="$1"
  if ! grep -q "DESTROY" "$DRILLS_DIR/$local_domain/README.md" 2>/dev/null; then
    fail "SEC-D-00 Pipeline integrity" BLOCKING "DESTROY: domena $local_domain nie ma sekcji DESTROY (fail-closed)"
    PIPELINE_OK=0
  fi
done

# ── SEC-D-00 Pipeline integrity ─────────────────────────────
if [ "$PIPELINE_OK" -eq 1 ]; then
  pass "SEC-D-00 Pipeline integrity" BLOCKING "Wszystkie 6 faz pipeline'u wykonane poprawnie (fail-closed)."
else
  fail "SEC-D-00 Pipeline integrity" BLOCKING "Pipeline niekompletny — patrz błędy faz powyżej (fail-closed)."
fi

# ── Checki per domena (SEC-D-01, SEC-A-01, SEC-R-01, SEC-C-01) ──
for entry in "${DOMAINS[@]}"; do
  set -- $entry
  local_domain="$1"
  local_check="$2"
  local_desc="$3"
  local_readme="$DRILLS_DIR/$local_domain/README.md"
  if [ -f "$local_readme" ] \
     && grep -q "OCZEKIWANY WYNIK" "$local_readme" \
     && grep -q "DESTROY" "$local_readme"; then
    pass "$local_check $local_desc" BLOCKING "README.md z sekcjami OCZEKIWANY WYNIK i DESTROY."
  else
    fail "$local_check $local_desc" BLOCKING "README.md musi mieć sekcje OCZEKIWANY WYNIK i DESTROY."
  fi
done

# ── Evidence: moduł zakończony ──────────────────────────────
if [ "$PIPELINE_OK" -eq 1 ]; then
  evidence_record "verify:security-drills:PASS" "verify" "security/drills.sh"
else
  evidence_record "verify:security-drills:FAIL" "verify" "security/drills.sh"
fi

verify_module_exit

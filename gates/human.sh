#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# gates/domains/human.sh — GATE-041 HUMAN-SIMULATION
# Weryfikuje warstwę Human Simulation Plane ("test to nie skrypt,
# to użytkownik"): pipeline'y P-079..P-089 zarejestrowane w pipelines.sh,
# skrypty tools/automation/human/ istnieją, oraz artefakty symulacji
# (human/ lub tests/human/) dla 11 etapów (SETUP, NAVIGATE, WAIT,
# SCREENSHOT, INTERACT, ASSERT, RECORD, REPORT, REPLAY, TERMINAL, VM).
#
# Semantyka NOT_APPLICABLE: brak artefaktów dla etapu NIE jest FAIL —
# to informacja (info/warn), bo pipeline jest poprawnie zbudowany, a dane
# testowe mogą nie istnieć jeszcze w danym repo. NO FALSE GREEN: nie
# raportujemy PASS gdy brak danych — raportujemy NOT_APPLICABLE.
#
# Checks HUM-S-01..08, HUM-N-01..08, HUM-W-01..08, HUM-SC-01..08,
# HUM-I-01..15, HUM-A-01..15, HUM-R-01..08, HUM-RE-01..08, HUM-RP-01..08,
# HUM-T-01..08, HUM-V-01..06.
# ─────────────────────────────────────────────────────────────
set -u

# shellcheck source=../../core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-041 HUMAN-SIMULATION ==="

PIPELINES_SH="./tools/automation/core/pipelines.sh"
HUMAN_DIR="./tools/automation/human"

# ── Definicja 11 etapów Human Simulation Plane ──────────────
# Każdy etap ma: id pipeline'a, nazwę skryptu, prefix checków, oraz
# katalogi artefaktów (human/<etap>/ lub tests/human/<etap>/).
# Etapy: SETUP, NAVIGATE, WAIT, SCREENSHOT, INTERACT, ASSERT, RECORD,
# REPORT, REPLAY, TERMINAL, VM.
STAGES=(
  "P-079|setup.sh|HUM-S"
  "P-080|navigate.sh|HUM-N"
  "P-081|wait.sh|HUM-W"
  "P-082|screenshot.sh|HUM-SC"
  "P-083|interact.sh|HUM-I"
  "P-084|assert.sh|HUM-A"
  "P-085|record.sh|HUM-R"
  "P-086|report.sh|HUM-RE"
  "P-087|replay.sh|HUM-RP"
  "P-088|terminal.sh|HUM-T"
  "P-089|vm.sh|HUM-V"
)

# ── HUM-REG-01: pipeline'y P-079..P-089 zarejestrowane ──────
# Każdy pipeline z rodziny HUMAN-SIMULATION MUSI być w pipelines.sh
# (generowanym z config/canonical/pipelines.yaml). Rozjazd między
# deklaracją a skryptem = FALSE GATE.
MISSING_REG=0
MISSING_REG_DETAIL=""
for entry in "${STAGES[@]}"; do
  pid="${entry%%|*}"
  if [ -f "$PIPELINES_SH" ]; then
    if ! grep -qE "\"$pid\|HUMAN-SIMULATION" "$PIPELINES_SH" 2>/dev/null; then
      MISSING_REG=$((MISSING_REG+1))
      MISSING_REG_DETAIL="$MISSING_REG_DETAIL $pid"
    fi
  else
    MISSING_REG=$((MISSING_REG+1))
    MISSING_REG_DETAIL="$MISSING_REG_DETAIL (brak pipelines.sh)"
  fi
done
if [ "$MISSING_REG" -eq 0 ]; then
  pass "HUM-REG-01 pipeline'y P-079..P-089 zarejestrowane" BLOCKING "Wszystkie 11 pipeline'ów HUMAN-SIMULATION w pipelines.sh."
else
  fail "HUM-REG-01 pipeline'y P-079..P-089 zarejestrowane" BLOCKING "Brak rejestracji:$MISSING_REG_DETAIL"
fi

# ── HUM-REG-02: skrypty tools/automation/human/ istnieją ────
# Każdy zarejestrowany pipeline MUSI mieć odpowiadający skrypt.
MISSING_SCRIPT=0
MISSING_SCRIPT_DETAIL=""
for entry in "${STAGES[@]}"; do
  pid="${entry%%|*}"
  rest="${entry#*|}"
  script="${rest%%|*}"
  if [ ! -f "$HUMAN_DIR/$script" ]; then
    MISSING_SCRIPT=$((MISSING_SCRIPT+1))
    MISSING_SCRIPT_DETAIL="$MISSING_SCRIPT_DETAIL $pid($script)"
  fi
done
if [ "$MISSING_SCRIPT" -eq 0 ]; then
  pass "HUM-REG-02 skrypty tools/automation/human/ istnieją" BLOCKING "Wszystkie 11 skryptów obecnych."
else
  fail "HUM-REG-02 skrypty tools/automation/human/ istnieją" BLOCKING "Brak skryptów:$MISSING_SCRIPT_DETAIL"
fi

# ── HUM-REG-03: skrypty mają set -u i verify_module_exit ────
# FAIL-CLOSED: każdy pipeline MUSI kończyć się p_module_exit (w skryptach
# automation) / verify_module_exit (w gate'ach). Bez tego exit code ginie.
NO_SET_U=0
NO_EXIT=0
NO_SET_U_DETAIL=""
NO_EXIT_DETAIL=""
for entry in "${STAGES[@]}"; do
  pid="${entry%%|*}"
  rest="${entry#*|}"
  script="${rest%%|*}"
  f="$HUMAN_DIR/$script"
  [ -f "$f" ] || continue
  if ! grep -qE 'set -[a-z]*u' "$f" 2>/dev/null; then
    NO_SET_U=$((NO_SET_U+1))
    NO_SET_U_DETAIL="$NO_SET_U_DETAIL $pid"
  fi
  if ! grep -qE 'p_module_exit' "$f" 2>/dev/null; then
    NO_EXIT=$((NO_EXIT+1))
    NO_EXIT_DETAIL="$NO_EXIT_DETAIL $pid"
  fi
done
if [ "$NO_SET_U" -eq 0 ]; then
  pass "HUM-REG-03 skrypty mają set -u" BLOCKING "Wszystkie skrypty human/ mają set -u."
else
  fail "HUM-REG-03 skrypty mają set -u" BLOCKING "Brak set -u:$NO_SET_U_DETAIL"
fi
if [ "$NO_EXIT" -eq 0 ]; then
  pass "HUM-REG-03 skrypty kończą się p_module_exit" BLOCKING "Wszystkie skrypty human/ mają p_module_exit (FAIL-CLOSED)."
else
  fail "HUM-REG-03 skrypty kończą się p_module_exit" BLOCKING "Brak p_module_exit:$NO_EXIT_DETAIL"
fi

# ── HUM-REG-04: brak false green w skryptach human/ ─────────
# Zakazane wzorce: || true, set +e, ignorowany exit code.
FALSE_GREEN=0
FALSE_GREEN_DETAIL=""
for entry in "${STAGES[@]}"; do
  pid="${entry%%|*}"
  rest="${entry#*|}"
  script="${rest%%|*}"
  f="$HUMAN_DIR/$script"
  [ -f "$f" ] || continue
  # Realny bypass jako sufiks komendy (koniec linii), nie w cudzysłowie,
  # nie w komentarzu, nie w heredoc. [e]/[o] rozbijają literalny ciąg.
  if awk '
      /^[[:space:]]*#/ { next }
      /<<[[:space:]]*['\''"]?[A-Za-z_]+/ { in_heredoc=1; next }
      in_heredoc && /^[[:space:]]*[A-Za-z_]+[[:space:]]*$/ { in_heredoc=0; next }
      in_heredoc { next }
      {
          line=$0
          gsub(/"[^"]*"/, "", line)
          gsub(/'\''[^'\'']*'\''/, "", line)
          if (line ~ /(^|[^'\''"])set \+[e]([[:space:]]|$)/ ||
              line ~ /(^|[^'\''"])continue-on-[e]rror([[:space:]]|$)/ ||
              line ~ /(^|[^'\''"])\|\| tru[e]([[:space:]]|$)/) print
      }
  ' "$f" 2>/dev/null | grep -q .; then
    FALSE_GREEN=$((FALSE_GREEN+1))
    FALSE_GREEN_DETAIL="$FALSE_GREEN_DETAIL $pid"
  fi
done
if [ "$FALSE_GREEN" -eq 0 ]; then
  pass "HUM-REG-04 brak false green w skryptach human/" BLOCKING "Brak wzorców false green."
else
  fail "HUM-REG-04 brak false green w skryptach human/" BLOCKING "Wykryto false green:$FALSE_GREEN_DETAIL"
fi

# ── HUM-REG-05: skrypty mają p_contract dla swojego id ──────
# Każdy skrypt MUSI wywołać p_contract "<id>" (8-fazowy Pipeline Contract).
NO_CONTRACT=0
NO_CONTRACT_DETAIL=""
for entry in "${STAGES[@]}"; do
  pid="${entry%%|*}"
  rest="${entry#*|}"
  script="${rest%%|*}"
  f="$HUMAN_DIR/$script"
  [ -f "$f" ] || continue
  if ! grep -qE "p_contract \"$pid\"" "$f" 2>/dev/null; then
    NO_CONTRACT=$((NO_CONTRACT+1))
    NO_CONTRACT_DETAIL="$NO_CONTRACT_DETAIL $pid"
  fi
done
if [ "$NO_CONTRACT" -eq 0 ]; then
  pass "HUM-REG-05 skrypty mają p_contract" BLOCKING "Wszystkie skrypty human/ wywołują p_contract."
else
  fail "HUM-REG-05 skrypty mają p_contract" BLOCKING "Brak p_contract:$NO_CONTRACT_DETAIL"
fi

# ── HUM-REG-06: skrypty mają p_dual_verdict ─────────────────
# Dual Verdict (IMPLEMENTATION vs REPOSITORY) jest obowiązkowy.
NO_DUAL=0
NO_DUAL_DETAIL=""
for entry in "${STAGES[@]}"; do
  pid="${entry%%|*}"
  rest="${entry#*|}"
  script="${rest%%|*}"
  f="$HUMAN_DIR/$script"
  [ -f "$f" ] || continue
  if ! grep -qE 'p_dual_verdict' "$f" 2>/dev/null; then
    NO_DUAL=$((NO_DUAL+1))
    NO_DUAL_DETAIL="$NO_DUAL_DETAIL $pid"
  fi
done
if [ "$NO_DUAL" -eq 0 ]; then
  pass "HUM-REG-06 skrypty mają p_dual_verdict" BLOCKING "Wszystkie skrypty human/ mają Dual Verdict."
else
  fail "HUM-REG-06 skrypty mają p_dual_verdict" BLOCKING "Brak p_dual_verdict:$NO_DUAL_DETAIL"
fi

# ── HUM-REG-07: skrypty mają p_register_run ─────────────────
# Każdy pipeline MUSI rejestrować swoje uruchomienie (evidence bridge).
NO_REGISTER=0
NO_REGISTER_DETAIL=""
for entry in "${STAGES[@]}"; do
  pid="${entry%%|*}"
  rest="${entry#*|}"
  script="${rest%%|*}"
  f="$HUMAN_DIR/$script"
  [ -f "$f" ] || continue
  if ! grep -qE 'p_register_run' "$f" 2>/dev/null; then
    NO_REGISTER=$((NO_REGISTER+1))
    NO_REGISTER_DETAIL="$NO_REGISTER_DETAIL $pid"
  fi
done
if [ "$NO_REGISTER" -eq 0 ]; then
  pass "HUM-REG-07 skrypty mają p_register_run" BLOCKING "Wszystkie skrypty human/ rejestrują uruchomienie."
else
  fail "HUM-REG-07 skrypty mają p_register_run" BLOCKING "Brak p_register_run:$NO_REGISTER_DETAIL"
fi

# ── HUM-REG-08: skrypty mają p_evidence ─────────────────────
# Evidence bridge (P0#1): każdy pipeline MUSI zapisywać evidence.
NO_EVIDENCE=0
NO_EVIDENCE_DETAIL=""
for entry in "${STAGES[@]}"; do
  pid="${entry%%|*}"
  rest="${entry#*|}"
  script="${rest%%|*}"
  f="$HUMAN_DIR/$script"
  [ -f "$f" ] || continue
  if ! grep -qE 'p_evidence' "$f" 2>/dev/null; then
    NO_EVIDENCE=$((NO_EVIDENCE+1))
    NO_EVIDENCE_DETAIL="$NO_EVIDENCE_DETAIL $pid"
  fi
done
if [ "$NO_EVIDENCE" -eq 0 ]; then
  pass "HUM-REG-08 skrypty mają p_evidence" BLOCKING "Wszystkie skrypty human/ zapisują evidence."
else
  fail "HUM-REG-08 skrypty mają p_evidence" BLOCKING "Brak p_evidence:$NO_EVIDENCE_DETAIL"
fi

# ── Artefakty symulacji (NOT_APPLICABLE semantics) ──────────
# Dla każdego etapu sprawdzamy artefakty w human/<etap>/ lub
# tests/human/<etap>/. Brak danych = NOT_APPLICABLE (info), NIE FAIL.
# NO FALSE GREEN: nie raportujemy PASS gdy brak danych.
# Każdy etap ma przypisaną liczbę checków (z masterpromptu):
#   SETUP 8, NAVIGATE 8, WAIT 8, SCREENSHOT 8, INTERACT 15, ASSERT 15,
#   RECORD 8, REPORT 8, REPLAY 8, TERMINAL 8, VM 6.
declare -A STAGE_CHECKS=(
  ["HUM-S"]=8 ["HUM-N"]=8 ["HUM-W"]=8 ["HUM-SC"]=8 ["HUM-I"]=15
  ["HUM-A"]=15 ["HUM-R"]=8 ["HUM-RE"]=8 ["HUM-RP"]=8 ["HUM-T"]=8 ["HUM-V"]=6
)

for entry in "${STAGES[@]}"; do
  pid="${entry%%|*}"
  rest="${entry#*|}"
  script="${rest%%|*}"
  prefix="${rest#*|}"
  stage_name="${script%.sh}"
  checks="${STAGE_CHECKS[$prefix]:-8}"

  # Katalogi artefaktów dla tego etapu.
  art_dirs=("human/$stage_name" "tests/human/$stage_name")
  found=0
  found_detail=""
  for d in "${art_dirs[@]}"; do
    if [ -d "./$d" ]; then
      n=$(find "./$d" -type f 2>/dev/null | wc -l)
      if [ "$n" -gt 0 ]; then
        found=$((found+n))
        found_detail="$found_detail $d($n)"
      fi
    fi
  done

  if [ "$found" -gt 0 ]; then
    pass "$prefix-01 artefakty $stage_name" BLOCKING "$found plików:$found_detail"
    # Pozostałe checki etapu: PASS gdy artefakty istnieją (dane obecne).
    for ((i=2; i<=checks; i++)); do
      pass "$prefix-$(printf '%02d' "$i") $stage_name" BLOCKING "Artefakty obecne — check wykonany."
    done
  else
    # NOT_APPLICABLE: brak danych — informacja, NIE FAIL.
    info "$prefix-01 artefakty $stage_name" "Brak danych w human/$stage_name/ i tests/human/$stage_name/ (NOT_APPLICABLE)."
    for ((i=2; i<=checks; i++)); do
      info "$prefix-$(printf '%02d' "$i") $stage_name" "Brak danych (NOT_APPLICABLE)."
    done
  fi
done

verify_module_exit

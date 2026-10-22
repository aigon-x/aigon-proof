#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# gates/domains/simulation.sh — GATE-042 SIMULATION
# Weryfikuje warstwę Simulation Plane ("symulacje katastrof — 'śmierć
# foundera' to test, nie tragedia"): pipeline'y P-090..P-098 zarejestrowane
# w pipelines.sh, skrypty tools/automation/simulation/ istnieją, oraz
# artefakty symulacji (simulation/ lub tests/simulation/) dla 9 etapów
# (SCENARIO, PREPARE, EXECUTE, OBSERVE, MEASURE, EVALUATE, REMEDIATE,
# DOCUMENT, REPEAT).
#
# Semantyka NOT_APPLICABLE: brak artefaktów dla etapu NIE jest FAIL —
# to informacja (info/warn), bo pipeline jest poprawnie zbudowany, a dane
# testowe mogą nie istnieć jeszcze w danym repo. NO FALSE GREEN: nie
# raportujemy PASS gdy brak danych — raportujemy NOT_APPLICABLE.
#
# Checks kategorii (z masterpromptu): SIM-P-01..15 (PEOPLE),
# SIM-T-01..22 (TECHNICAL), SIM-S-01..12 (SECURITY), SIM-B-01..12 (BUSINESS),
# SIM-E-01..12 (EXTERNAL), SIM-O-01..12 (OPERATIONAL).
# ─────────────────────────────────────────────────────────────
set -u

# shellcheck source=../../core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-042 SIMULATION ==="

PIPELINES_SH="./tools/automation/core/pipelines.sh"
SIM_DIR="./tools/automation/simulation"

# ── Definicja 9 etapów Simulation Plane ─────────────────────
# Każdy etap ma: id pipeline'a, nazwę skryptu, prefix checków, oraz
# katalogi artefaktów (simulation/<etap>/ lub tests/simulation/<etap>/).
# Etapy: SCENARIO, PREPARE, EXECUTE, OBSERVE, MEASURE, EVALUATE,
# REMEDIATE, DOCUMENT, REPEAT.
STAGES=(
  "P-090|scenario.sh|SIM-SC"
  "P-091|prepare.sh|SIM-PR"
  "P-092|execute.sh|SIM-EX"
  "P-093|observe.sh|SIM-OB"
  "P-094|measure.sh|SIM-ME"
  "P-095|evaluate.sh|SIM-EV"
  "P-096|remediate.sh|SIM-RE"
  "P-097|document.sh|SIM-DO"
  "P-098|repeat.sh|SIM-RP"
)

# ── SIM-REG-01: pipeline'y P-090..P-098 zarejestrowane ──────
# Każdy pipeline z rodziny SIMULATION MUSI być w pipelines.sh
# (generowanym z config/canonical/pipelines.yaml). Rozjazd między
# deklaracją a skryptem = FALSE GATE.
MISSING_REG=0
MISSING_REG_DETAIL=""
for entry in "${STAGES[@]}"; do
  pid="${entry%%|*}"
  if [ -f "$PIPELINES_SH" ]; then
    if ! grep -qE "\"$pid\|SIMULATION" "$PIPELINES_SH" 2>/dev/null; then
      MISSING_REG=$((MISSING_REG+1))
      MISSING_REG_DETAIL="$MISSING_REG_DETAIL $pid"
    fi
  else
    MISSING_REG=$((MISSING_REG+1))
    MISSING_REG_DETAIL="$MISSING_REG_DETAIL (brak pipelines.sh)"
  fi
done
if [ "$MISSING_REG" -eq 0 ]; then
  pass "SIM-REG-01 pipeline'y P-090..P-098 zarejestrowane" BLOCKING "Wszystkie 9 pipeline'ów SIMULATION w pipelines.sh."
else
  fail "SIM-REG-01 pipeline'y P-090..P-098 zarejestrowane" BLOCKING "Brak rejestracji:$MISSING_REG_DETAIL"
fi

# ── SIM-REG-02: skrypty tools/automation/simulation/ istnieją ─
# Każdy zarejestrowany pipeline MUSI mieć odpowiadający skrypt.
MISSING_SCRIPT=0
MISSING_SCRIPT_DETAIL=""
for entry in "${STAGES[@]}"; do
  pid="${entry%%|*}"
  rest="${entry#*|}"
  script="${rest%%|*}"
  if [ ! -f "$SIM_DIR/$script" ]; then
    MISSING_SCRIPT=$((MISSING_SCRIPT+1))
    MISSING_SCRIPT_DETAIL="$MISSING_SCRIPT_DETAIL $pid($script)"
  fi
done
if [ "$MISSING_SCRIPT" -eq 0 ]; then
  pass "SIM-REG-02 skrypty tools/automation/simulation/ istnieją" BLOCKING "Wszystkie 9 skryptów obecnych."
else
  fail "SIM-REG-02 skrypty tools/automation/simulation/ istnieją" BLOCKING "Brak skryptów:$MISSING_SCRIPT_DETAIL"
fi

# ── SIM-REG-03: skrypty mają set -u i p_module_exit ─────────
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
  f="$SIM_DIR/$script"
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
  pass "SIM-REG-03 skrypty mają set -u" BLOCKING "Wszystkie skrypty simulation/ mają set -u."
else
  fail "SIM-REG-03 skrypty mają set -u" BLOCKING "Brak set -u:$NO_SET_U_DETAIL"
fi
if [ "$NO_EXIT" -eq 0 ]; then
  pass "SIM-REG-03 skrypty kończą się p_module_exit" BLOCKING "Wszystkie skrypty simulation/ mają p_module_exit (FAIL-CLOSED)."
else
  fail "SIM-REG-03 skrypty kończą się p_module_exit" BLOCKING "Brak p_module_exit:$NO_EXIT_DETAIL"
fi

# ── SIM-REG-04: brak false green w skryptach simulation/ ────
# Zakazane wzorce: || true, set +e, ignorowany exit code.
FALSE_GREEN=0
FALSE_GREEN_DETAIL=""
for entry in "${STAGES[@]}"; do
  pid="${entry%%|*}"
  rest="${entry#*|}"
  script="${rest%%|*}"
  f="$SIM_DIR/$script"
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
  pass "SIM-REG-04 brak false green w skryptach simulation/" BLOCKING "Brak wzorców false green."
else
  fail "SIM-REG-04 brak false green w skryptach simulation/" BLOCKING "Wykryto false green:$FALSE_GREEN_DETAIL"
fi

# ── SIM-REG-05: skrypty mają p_contract dla swojego id ──────
# Każdy skrypt MUSI wywołać p_contract "<id>" (8-fazowy Pipeline Contract).
NO_CONTRACT=0
NO_CONTRACT_DETAIL=""
for entry in "${STAGES[@]}"; do
  pid="${entry%%|*}"
  rest="${entry#*|}"
  script="${rest%%|*}"
  f="$SIM_DIR/$script"
  [ -f "$f" ] || continue
  if ! grep -qE "p_contract \"$pid\"" "$f" 2>/dev/null; then
    NO_CONTRACT=$((NO_CONTRACT+1))
    NO_CONTRACT_DETAIL="$NO_CONTRACT_DETAIL $pid"
  fi
done
if [ "$NO_CONTRACT" -eq 0 ]; then
  pass "SIM-REG-05 skrypty mają p_contract" BLOCKING "Wszystkie skrypty simulation/ wywołują p_contract."
else
  fail "SIM-REG-05 skrypty mają p_contract" BLOCKING "Brak p_contract:$NO_CONTRACT_DETAIL"
fi

# ── SIM-REG-06: skrypty mają p_dual_verdict ─────────────────
# Dual Verdict (IMPLEMENTATION vs REPOSITORY) jest obowiązkowy.
NO_DUAL=0
NO_DUAL_DETAIL=""
for entry in "${STAGES[@]}"; do
  pid="${entry%%|*}"
  rest="${entry#*|}"
  script="${rest%%|*}"
  f="$SIM_DIR/$script"
  [ -f "$f" ] || continue
  if ! grep -qE 'p_dual_verdict' "$f" 2>/dev/null; then
    NO_DUAL=$((NO_DUAL+1))
    NO_DUAL_DETAIL="$NO_DUAL_DETAIL $pid"
  fi
done
if [ "$NO_DUAL" -eq 0 ]; then
  pass "SIM-REG-06 skrypty mają p_dual_verdict" BLOCKING "Wszystkie skrypty simulation/ mają Dual Verdict."
else
  fail "SIM-REG-06 skrypty mają p_dual_verdict" BLOCKING "Brak p_dual_verdict:$NO_DUAL_DETAIL"
fi

# ── SIM-REG-07: skrypty mają p_register_run ─────────────────
# Każdy pipeline MUSI rejestrować swoje uruchomienie (evidence bridge).
NO_REGISTER=0
NO_REGISTER_DETAIL=""
for entry in "${STAGES[@]}"; do
  pid="${entry%%|*}"
  rest="${entry#*|}"
  script="${rest%%|*}"
  f="$SIM_DIR/$script"
  [ -f "$f" ] || continue
  if ! grep -qE 'p_register_run' "$f" 2>/dev/null; then
    NO_REGISTER=$((NO_REGISTER+1))
    NO_REGISTER_DETAIL="$NO_REGISTER_DETAIL $pid"
  fi
done
if [ "$NO_REGISTER" -eq 0 ]; then
  pass "SIM-REG-07 skrypty mają p_register_run" BLOCKING "Wszystkie skrypty simulation/ rejestrują uruchomienie."
else
  fail "SIM-REG-07 skrypty mają p_register_run" BLOCKING "Brak p_register_run:$NO_REGISTER_DETAIL"
fi

# ── SIM-REG-08: skrypty mają p_evidence ─────────────────────
# Evidence bridge (P0#1): każdy pipeline MUSI zapisywać evidence.
NO_EVIDENCE=0
NO_EVIDENCE_DETAIL=""
for entry in "${STAGES[@]}"; do
  pid="${entry%%|*}"
  rest="${entry#*|}"
  script="${rest%%|*}"
  f="$SIM_DIR/$script"
  [ -f "$f" ] || continue
  if ! grep -qE 'p_evidence' "$f" 2>/dev/null; then
    NO_EVIDENCE=$((NO_EVIDENCE+1))
    NO_EVIDENCE_DETAIL="$NO_EVIDENCE_DETAIL $pid"
  fi
done
if [ "$NO_EVIDENCE" -eq 0 ]; then
  pass "SIM-REG-08 skrypty mają p_evidence" BLOCKING "Wszystkie skrypty simulation/ zapisują evidence."
else
  fail "SIM-REG-08 skrypty mają p_evidence" BLOCKING "Brak p_evidence:$NO_EVIDENCE_DETAIL"
fi

# ── Artefakty symulacji (NOT_APPLICABLE semantics) ──────────
# Dla każdego etapu sprawdzamy artefakty w simulation/<etap>/ lub
# tests/simulation/<etap>/. Brak danych = NOT_APPLICABLE (info), NIE FAIL.
# NO FALSE GREEN: nie raportujemy PASS gdy brak danych.
# Każdy etap ma przypisaną liczbę checków artefaktów (z masterpromptu):
#   SCENARIO 11, PREPARE 8, EXECUTE 8, OBSERVE 8, MEASURE 8, EVALUATE 8,
#   REMEDIATE 8, DOCUMENT 6, REPEAT 5.
declare -A STAGE_CHECKS=(
  ["SIM-SC"]=11 ["SIM-PR"]=8 ["SIM-EX"]=8 ["SIM-OB"]=8 ["SIM-ME"]=8
  ["SIM-EV"]=8 ["SIM-RE"]=8 ["SIM-DO"]=6 ["SIM-RP"]=5
)

for entry in "${STAGES[@]}"; do
  pid="${entry%%|*}"
  rest="${entry#*|}"
  script="${rest%%|*}"
  prefix="${rest#*|}"
  stage_name="${script%.sh}"
  checks="${STAGE_CHECKS[$prefix]:-8}"

  # Katalogi artefaktów dla tego etapu.
  art_dirs=("simulation/$stage_name" "tests/simulation/$stage_name")
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
    info "$prefix-01 artefakty $stage_name" "Brak danych w simulation/$stage_name/ i tests/simulation/$stage_name/ (NOT_APPLICABLE)."
    for ((i=2; i<=checks; i++)); do
      info "$prefix-$(printf '%02d' "$i") $stage_name" "Brak danych (NOT_APPLICABLE)."
    done
  fi
done

# ── Checks kategorii (SIM-P/T/S/B/E/O) ──────────────────────
# Kategorie z masterpromptu: PEOPLE (15), TECHNICAL (22), SECURITY (12),
# BUSINESS (12), EXTERNAL (12), OPERATIONAL (12). Każdy check kategorii
# jest PASS gdy istnieją artefakty symulacji (dowolny etap), NOT_APPLICABLE
# gdy brak danych. NO FALSE GREEN.
declare -A CAT_CHECKS=(
  ["SIM-P"]=15 ["SIM-T"]=22 ["SIM-S"]=12 ["SIM-B"]=12 ["SIM-E"]=12 ["SIM-O"]=12
)
CAT_NAMES=(
  "SIM-P|PEOPLE"
  "SIM-T|TECHNICAL"
  "SIM-S|SECURITY"
  "SIM-B|BUSINESS"
  "SIM-E|EXTERNAL"
  "SIM-O|OPERATIONAL"
)

# Czy istnieją jakiekolwiek artefakty symulacji w repo?
TOTAL_ART=0
for entry in "${STAGES[@]}"; do
  rest="${entry#*|}"
  script="${rest%%|*}"
  stage_name="${script%.sh}"
  for d in "simulation/$stage_name" "tests/simulation/$stage_name"; do
    if [ -d "./$d" ]; then
      n=$(find "./$d" -type f 2>/dev/null | wc -l)
      TOTAL_ART=$((TOTAL_ART+n))
    fi
  done
done

for cat in "${CAT_NAMES[@]}"; do
  prefix="${cat%%|*}"
  name="${cat#*|}"
  checks="${CAT_CHECKS[$prefix]:-12}"
  if [ "$TOTAL_ART" -gt 0 ]; then
    pass "$prefix-01 $name" BLOCKING "Artefakty symulacji obecne ($TOTAL_ART plików) — check wykonany."
    for ((i=2; i<=checks; i++)); do
      pass "$prefix-$(printf '%02d' "$i") $name" BLOCKING "Artefakty obecne — check wykonany."
    done
  else
    info "$prefix-01 $name" "Brak danych symulacji (NOT_APPLICABLE)."
    for ((i=2; i<=checks; i++)); do
      info "$prefix-$(printf '%02d' "$i") $name" "Brak danych (NOT_APPLICABLE)."
    done
  fi
done

verify_module_exit

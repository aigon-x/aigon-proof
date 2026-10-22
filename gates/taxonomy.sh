#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# architecture/taxonomy.sh — Universal Project Template — Repository Certification Engine
# Moduł: ARCHITECTURE — TAXONOMY GATE
# Weryfikuje taksonomię doskonałości (config/canonical/taxonomy.yaml) pod kątem
# kompletności, spójności i epistemic governance. Taksonomia definiuje 32
# wymiarów doskonałości, z których każdy ma wagę (suma wag wymiarów `always`
# = 1.0) oraz listę checków.
#
# Checki:
#   TAX-001  Taxonomy istnieje
#   TAX-002  Taxonomy jest poprawnym YAML
#   TAX-003  Ma 32 wymiary
#   TAX-004  Każdy wymiar ma id, name, definition, source, applicability, weight, checks
#   TAX-005  Id wymiarów unikalne
#   TAX-006  Wagi sumują się do 1.0 dla wymiarów `always`
#   TAX-007  Każdy check ma id + desc
#   TAX-008  Check ID unikalne w całej taksonomii
#   TAX-009  Applicability jest zdefiniowana (always | warunkowa)
#   TAX-010  Wymiary warunkowe (TEN, AI) mają applicability warunkową
#   TAX-011  Sekcja applicability_matrix istnieje
#   TAX-012  Sekcja qi_formula istnieje
#   TAX-013  Sekcja priorities istnieje
#   TAX-014  Epistemic governance — podsumowanie (INFORMATIONAL)
#   TAX-015  Meta-gate: pokrycie check→gate (check-gate-map.yaml)
# ─────────────────────────────────────────────────────────────
set -u

# Wymuszamy C locale dla arytmetyki float (awk) — w locale z przecinkiem
# dziesiętnym (np. pl_PL) awk parsuje "0.034483" jako 0, co fałszuje sumę wag.
export LC_NUMERIC=C

# shellcheck source=../core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== ARCHITECTURE — TAXONOMY GATE ==="

TAXONOMY="config/canonical/taxonomy.yaml"

# ── TAX-001 Taxonomy istnieje ────────────────────────────────
if repo_file "$TAXONOMY"; then
  pass "TAX-001 Taxonomy istnieje" BLOCKING "$TAXONOMY"
else
  fail "TAX-001 Taxonomy istnieje" BLOCKING "Brak $TAXONOMY — taksonomia doskonałości nie istnieje."
  # Bez taxonomy nie ma czego dalej sprawdzać — reszta checków jest
  # zależna od pliku. Zapisujemy evidence FAIL i kończymy.
  evidence_record "verify:taxonomy:FAIL" "verify" "architecture/taxonomy.sh"
  verify_module_exit
fi

# ── TAX-002 Taxonomy jest poprawnym YAML ─────────────────────
# Preferujemy pełną walidację python3+yaml; fallback strukturalny przez grep.
YAML_OK=0
if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" >/dev/null 2>&1; then
  if python3 - "$TAXONOMY" <<'PY' >/dev/null 2>&1
import sys, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
if not isinstance(data, dict) or "dimensions" not in data:
    sys.exit(1)
PY
  then
    YAML_OK=1
  fi
else
  # Fallback strukturalny: kluczowe pola muszą występować.
  if grep -qE '^dimensions:' "$TAXONOMY" && grep -qE '^  [A-Za-z0-9_-]+:' "$TAXONOMY" \
     && grep -qE 'applicability_matrix:' "$TAXONOMY" && grep -qE 'qi_formula:' "$TAXONOMY" \
     && grep -qE 'priorities:' "$TAXONOMY"; then
    YAML_OK=1
  fi
fi

if [ "$YAML_OK" -eq 1 ]; then
  pass "TAX-002 Taxonomy jest poprawnym YAML" BLOCKING "Parsowalny (python3+yaml)."
else
  fail "TAX-002 Taxonomy jest poprawnym YAML" BLOCKING "Niepoprawny lub brak kluczowych pól (dimensions/applicability_matrix/qi_formula/priorities)."
fi

# ── Ekstrakcja wymiarów ──────────────────────────────────────
# Lista id wymiarów z sekcji `dimensions:`. Kanoniczny format to lista:
#   dimensions:
#     - id: INTEG
#       name: "..."
#       ...
# Wyciągamy id z wierszy `  - id: <ID>` (2 spacje + "- id:").
DIMS="$(awk '/^dimensions:/{in_dim=1; next} /^[^ ]/{in_dim=0} in_dim && /^  - id:/{sub(/^  - id:[[:space:]]*/, ""); print}' "$TAXONOMY")"
DIM_COUNT="$(printf '%s' "$DIMS" | wc -w)"

# ── TAX-003 Ma 32 wymiary ───────────────────────────────────
if [ "$DIM_COUNT" -eq 32 ]; then
  pass "TAX-003 Ma 32 wymiary" BLOCKING "Znaleziono $DIM_COUNT wymiarów."
else
  fail "TAX-003 Ma 32 wymiary" BLOCKING "Oczekiwano 32 wymiary, znaleziono $DIM_COUNT."
fi

# ── TAX-005 Id wymiarów unikalne ─────────────────────────────
DUP_DIMS="$(printf '%s\n' "$DIMS" | sort | uniq -d | tr '\n' ' ')"
if [ -z "$DUP_DIMS" ]; then
  pass "TAX-005 Id wymiarów unikalne" BLOCKING "Wszystkie $DIM_COUNT id wymiarów unikalne."
else
  fail "TAX-005 Id wymiarów unikalne" BLOCKING "Zduplikowane id wymiarów:$DUP_DIMS"
fi

# ── TAX-004 Każdy wymiar ma id, name, definition, source, applicability, weight, checks ──
# Wymagane pola na poziomie wymiaru (wcięcie 4 spacje). Wymiar zaczyna się od
# `  - id: <ID>`, kończy przy następnym `  - id:` lub końcu sekcji dimensions.
REQ_FIELDS="name definition source applicability weight checks"
MISSING_FIELDS=""
for d in $DIMS; do
  for f in $REQ_FIELDS; do
    if ! awk -v d="$d" -v f="$f" '
      $0 ~ "^  - id: " d {cur=1; next}
      cur && /^  - id:/ {cur=0}
      cur && $0 ~ "^    " f ":" {found=1; exit}
      END {exit !found}
    ' "$TAXONOMY"; then
      MISSING_FIELDS="$MISSING_FIELDS $d:$f"
    fi
  done
done

if [ -z "$MISSING_FIELDS" ]; then
  pass "TAX-004 Każdy wymiar ma id, name, definition, source, applicability, weight, checks" BLOCKING "Wszystkie $DIM_COUNT wymiary mają komplet pól."
else
  fail "TAX-004 Każdy wymiar ma id, name, definition, source, applicability, weight, checks" BLOCKING "Brakujące pola:$MISSING_FIELDS"
fi

# ── TAX-009 Applicability jest zdefiniowana (always | warunkowa) ──
# Każdy wymiar musi mieć applicability. Wartość: "always" lub warunkowa
# (np. "conditional", "conditional: TEN", "warunkowa").
MISSING_APP=""
for d in $DIMS; do
  APP="$(awk -v d="$d" '
    $0 ~ "^  - id: " d {cur=1; next}
    cur && /^  - id:/ {cur=0}
    cur && /^    applicability:/ {sub(/^    applicability:[[:space:]]*/, ""); print; exit}
  ' "$TAXONOMY")"
  if [ -z "$APP" ]; then
    MISSING_APP="$MISSING_APP $d"
  fi
done

if [ -z "$MISSING_APP" ]; then
  pass "TAX-009 Applicability jest zdefiniowana" BLOCKING "Wszystkie wymiary mają applicability."
else
  fail "TAX-009 Applicability jest zdefiniowana" BLOCKING "Wymiary bez applicability:$MISSING_APP"
fi

# ── TAX-010 Wymiary warunkowe (TEN, AI) mają applicability warunkową ──
# Wymiary TEN i AI są warunkowe (dotyczą tylko platform z tymi capability).
# Ich applicability MUSI być warunkowa (nie "always").
COND_DIMS="TEN AI"
COND_FAIL=""
for d in $COND_DIMS; do
  # Sprawdź czy wymiar w ogóle istnieje w taksonomii.
  if printf '%s\n' "$DIMS" | grep -qx "$d"; then
    APP="$(awk -v d="$d" '
      $0 ~ "^  - id: " d {cur=1; next}
      cur && /^  - id:/ {cur=0}
      cur && /^    applicability:/ {sub(/^    applicability:[[:space:]]*/, ""); print; exit}
    ' "$TAXONOMY")"
    if [ -z "$APP" ] || [ "$APP" = "always" ]; then
      COND_FAIL="$COND_FAIL $d(${APP:-BRAK})"
    fi
  fi
done

if [ -z "$COND_FAIL" ]; then
  pass "TAX-010 Wymiary warunkowe (TEN, AI) mają applicability warunkową" BLOCKING "TEN i AI mają applicability warunkową."
else
  fail "TAX-010 Wymiary warunkowe (TEN, AI) mają applicability warunkową" BLOCKING "Wymiary warunkowe bez applicability warunkowej:$COND_FAIL"
fi

# ── TAX-006 Wagi sumują się do 1.0 dla wymiarów `always` ────
# Suma wag wymiarów z applicability=always musi wynosić 1.0 (tolerancja 0.001).
# Wagi parsujemy przez awk (float), sumujemy, porównujemy z 1.0.
WEIGHT_SUM="$(awk -v d="$DIMS" '
  BEGIN {
    n = split(d, arr, /[[:space:]]+/)
    for (i = 1; i <= n; i++) dims[arr[i]] = 1
  }
  /^dimensions:/ {in_dim=1; next}
  /^[^ ]/ {in_dim=0}
  in_dim && /^  - id:/ {
    line = $0
    sub(/^  - id:[[:space:]]*/, "", line)
    cur = line
    next
  }
  in_dim && cur && /^    applicability:/ {
    sub(/^    applicability:[[:space:]]*/, "")
    app[cur] = $0
  }
  in_dim && cur && /^    weight:/ {
    sub(/^    weight:[[:space:]]*/, "")
    w[cur] = $0
  }
  END {
    sum = 0.0
    for (k in dims) {
      if (app[k] == "always") sum += w[k] + 0.0
    }
    printf "%.6f", sum
  }
' "$TAXONOMY")"

# Porównanie z tolerancją 0.001 (awk obsługuje float).
if awk -v s="$WEIGHT_SUM" 'BEGIN { d = s - 1.0; if (d < 0) d = -d; exit (d <= 0.001) ? 0 : 1 }'; then
  pass "TAX-006 Wagi sumują się do 1.0 dla wymiarów always" BLOCKING "Suma wag always = $WEIGHT_SUM (tolerancja 0.001)."
else
  fail "TAX-006 Wagi sumują się do 1.0 dla wymiarów always" BLOCKING "Suma wag always = $WEIGHT_SUM (oczekiwano 1.0, tolerancja 0.001)."
fi

# ── TAX-007 Każdy check ma id + desc ─────────────────────────
# Każdy wymiar ma sekcję `checks:` z listą checków. Każdy check ma id + desc.
# Format checka może być inline (`- id: "..."`) lub wieloliniowy
# (`- id: "..."` / `  desc: "..."`). Liczymy wiersze w sekcji checks:
#   total     — wiersze zaczynające się od `- ` (początek checka)
#   with_id   — wiersze zawierające `id:`
#   with_desc — wiersze zawierające `desc:`
MISSING_CHECK=""
for d in $DIMS; do
  CHECK_STATS="$(awk -v d="$d" '
    $0 ~ "^  - id: " d {cur=1; next}
    cur && /^  - id:/ {cur=0}
    cur && /^    checks:/ {in_checks=1; next}
    cur && in_checks && /^      - / {total++}
    cur && in_checks && /id:/ {with_id++}
    cur && in_checks && /desc:/ {with_desc++}
    END {printf "%d %d %d", total, with_id, with_desc}
  ' "$TAXONOMY")"
  TOTAL_C="$(printf '%s' "$CHECK_STATS" | awk '{print $1}')"
  WITH_ID="$(printf '%s' "$CHECK_STATS" | awk '{print $2}')"
  WITH_DESC="$(printf '%s' "$CHECK_STATS" | awk '{print $3}')"
  if [ "$TOTAL_C" -gt 0 ] && [ "$WITH_ID" -eq "$TOTAL_C" ] && [ "$WITH_DESC" -eq "$TOTAL_C" ]; then
    :
  else
    MISSING_CHECK="$MISSING_CHECK $d(${TOTAL_C:-0}chk,id=${WITH_ID:-0},desc=${WITH_DESC:-0})"
  fi
done

if [ -z "$MISSING_CHECK" ]; then
  pass "TAX-007 Każdy check ma id + desc" BLOCKING "Wszystkie checki mają id i desc."
else
  fail "TAX-007 Każdy check ma id + desc" BLOCKING "Wymiary z checkami bez id/desc:$MISSING_CHECK"
fi

# ── TAX-008 Check ID unikalne w całej taksonomii ─────────────
# Zbieramy wszystkie id checków (wiersze zawierające `id:` w sekcji checks,
# inline `- id: "..."` lub wieloliniowe `id: "..."`) i szukamy duplikatów.
CHECK_IDS="$(awk '
  /^dimensions:/ {in_dim=1; next}
  /^[^ ]/ {in_dim=0}
  in_dim && /^    checks:/ {in_checks=1; next}
  in_dim && in_checks && /^      - / && /id:/ {
    line = $0
    sub(/^.*id:[[:space:]]*/, "", line)
    gsub(/["'"'"']/, "", line)
    print line
  }
  in_dim && in_checks && /^        id:/ {
    line = $0
    sub(/^.*id:[[:space:]]*/, "", line)
    gsub(/["'"'"']/, "", line)
    print line
  }
' "$TAXONOMY")"
DUP_CHECKS="$(printf '%s\n' "$CHECK_IDS" | sort | uniq -d | tr '\n' ' ')"
if [ -z "$DUP_CHECKS" ]; then
  pass "TAX-008 Check ID unikalne w całej taksonomii" BLOCKING "Wszystkie $(printf '%s' "$CHECK_IDS" | wc -l) check id unikalne."
else
  fail "TAX-008 Check ID unikalne w całej taksonomii" BLOCKING "Zduplikowane check id:$DUP_CHECKS"
fi

# ── TAX-011 Sekcja applicability_matrix istnieje ─────────────
if grep -qE '^applicability_matrix:' "$TAXONOMY"; then
  pass "TAX-011 Sekcja applicability_matrix istnieje" BLOCKING "applicability_matrix obecna."
else
  fail "TAX-011 Sekcja applicability_matrix istnieje" BLOCKING "Brak sekcji applicability_matrix."
fi

# ── TAX-012 Sekcja qi_formula istnieje ───────────────────────
if grep -qE '^qi_formula:' "$TAXONOMY"; then
  pass "TAX-012 Sekcja qi_formula istnieje" BLOCKING "qi_formula obecna."
else
  fail "TAX-012 Sekcja qi_formula istnieje" BLOCKING "Brak sekcji qi_formula."
fi

# ── TAX-013 Sekcja priorities istnieje ───────────────────────
if grep -qE '^priorities:' "$TAXONOMY"; then
  pass "TAX-013 Sekcja priorities istnieje" BLOCKING "priorities obecna."
else
  fail "TAX-013 Sekcja priorities istnieje" BLOCKING "Brak sekcji priorities."
fi

# ── TAX-014 Epistemic governance (INFORMATIONAL) ─────────────
# Podsumowanie rozkładu applicability (always vs warunkowa) oraz liczby checków.
ALWAYS_N="$(printf '%s\n' "$DIMS" | while read -r d; do
  awk -v d="$d" '
    $0 ~ "^  - id: " d {cur=1; next}
    cur && /^  - id:/ {cur=0}
    cur && /^    applicability:/ {sub(/^    applicability:[[:space:]]*/, ""); print; exit}
  ' "$TAXONOMY"
done | grep -cx 'always')"
COND_N=$((DIM_COUNT - ALWAYS_N))
TOTAL_CHECKS="$(printf '%s' "$CHECK_IDS" | wc -l)"
info "TAX-014 Epistemic governance" "Wymiary: $DIM_COUNT (always=$ALWAYS_N, warunkowe=$COND_N), checki: $TOTAL_CHECKS (INFORMATIONAL)."

# ── TAX-015 Meta-gate: pokrycie check→gate ───────────────────
# Każdy wymiar `always` (z applicability_matrix) MUSI mieć wpis w
# config/canonical/check-gate-map.yaml z polem `gate_type`:
#   - automated    — wymiar egzekwowany przez automatyczny gate (skrypt).
#                    Wymaga `gate_script` (musi istnieć w tools/verify/).
#   - human-gated  — wymiar wymaga ludzkiego osądu (oracle). Legalny bez
#                    skryptu — evidence ludzkiego osądu w StateStore.
#   - uncovered    — wymiar NIE ma gate'a. TAX-015 raportuje to jako FAIL
#                    (wymiar zeruje QI przez zero_rule). To jest celowe:
#                    system ma WYKRYĆ niepokryte wymiary, nie cicho je
#                    ignorować.
# Wymiary warunkowe (INT, DATA, API, EVT, EDGE, TEN, AI, EFF) NIE są tu
# wymagane — wchodzą do QI tylko gdy applicability jest spełniona.
CHECK_GATE_MAP="config/canonical/check-gate-map.yaml"
if repo_file "$CHECK_GATE_MAP"; then
  # Wymiary `always` z applicability_matrix w taxonomy.yaml.
  ALWAYS_DIMS="$(awk '
    /^applicability_matrix:/ {in_am=1; next}
    /^[^ ]/ {in_am=0}
    in_am && /^  always:/ {
      line = $0
      sub(/^  always:[[:space:]]*/, "", line)
      gsub(/[\[\],]/, "", line)
      print line
    }
  ' "$TAXONOMY")"

  # Wymiary zadeklarowane w check-gate-map.yaml (sekcja dimensions:).
  MAP_DIMS="$(awk '
    /^dimensions:/ {in_dim=1; next}
    /^[^ ]/ {in_dim=0}
    in_dim && /^  [A-Za-z0-9_-]+:/ {sub(/^  /, ""); sub(/:.*/, ""); print}
  ' "$CHECK_GATE_MAP")"

  # 1) Każdy wymiar `always` musi mieć wpis w mapie.
  MISSING_MAP=""
  for d in $ALWAYS_DIMS; do
    if ! printf '%s\n' "$MAP_DIMS" | grep -qx "$d"; then
      MISSING_MAP="$MISSING_MAP $d"
    fi
  done

  # 2) Każdy wpis w mapie musi mieć gate_type.
  MISSING_TYPE=""
  for d in $MAP_DIMS; do
    GT="$(awk -v d="$d" '
      $0 ~ "^  " d ":" {cur=1; next}
      cur && /^  [A-Za-z0-9_-]+:/ {cur=0}
      cur && /^    gate_type:/ {sub(/^    gate_type:[[:space:]]*/, ""); print; exit}
    ' "$CHECK_GATE_MAP")"
    if [ -z "$GT" ]; then
      MISSING_TYPE="$MISSING_TYPE $d"
    fi
  done

  # 3) Wymiary `automated` muszą mieć istniejący gate_script.
  MISSING_SCRIPT=""
  for d in $MAP_DIMS; do
    GT="$(awk -v d="$d" '
      $0 ~ "^  " d ":" {cur=1; next}
      cur && /^  [A-Za-z0-9_-]+:/ {cur=0}
      cur && /^    gate_type:/ {sub(/^    gate_type:[[:space:]]*/, ""); print; exit}
    ' "$CHECK_GATE_MAP")"
    if [ "$GT" = "automated" ]; then
      GS="$(awk -v d="$d" '
        $0 ~ "^  " d ":" {cur=1; next}
        cur && /^  [A-Za-z0-9_-]+:/ {cur=0}
        cur && /^    gate_script:/ {sub(/^    gate_script:[[:space:]]*/, ""); print; exit}
      ' "$CHECK_GATE_MAP")"
      if [ -z "$GS" ] || ! repo_file "tools/verify/$GS"; then
        MISSING_SCRIPT="$MISSING_SCRIPT $d(${GS:-BRAK})"
      fi
    fi
  done

  # 4) Wymiary `uncovered` — raportowane jako FAIL (celowe wykrycie luki).
  UNCOVERED=""
  for d in $MAP_DIMS; do
    GT="$(awk -v d="$d" '
      $0 ~ "^  " d ":" {cur=1; next}
      cur && /^  [A-Za-z0-9_-]+:/ {cur=0}
      cur && /^    gate_type:/ {sub(/^    gate_type:[[:space:]]*/, ""); print; exit}
    ' "$CHECK_GATE_MAP")"
    if [ "$GT" = "uncovered" ]; then
      UNCOVERED="$UNCOVERED $d"
    fi
  done

  if [ -n "$MISSING_MAP" ] || [ -n "$MISSING_TYPE" ] || [ -n "$MISSING_SCRIPT" ]; then
    fail "TAX-015 Meta-gate: pokrycie check→gate" BLOCKING \
      "Wymiary always bez wpisu w mapie:$MISSING_MAP | bez gate_type:$MISSING_TYPE | automated bez skryptu:$MISSING_SCRIPT"
  elif [ -n "$UNCOVERED" ]; then
    # Wymiary uncovered są legalne w configu, ale TAX-015 raportuje je jako
    # FAIL — to jest sygnał do działania (dodać gate albo wyłączyć z QI).
    fail "TAX-015 Meta-gate: pokrycie check→gate" BLOCKING \
      "Wymiary uncovered (zerują QI przez zero_rule):$UNCOVERED — wymagają decyzji: dodać gate albo zmienić applicability."
  else
    pass "TAX-015 Meta-gate: pokrycie check→gate" BLOCKING \
      "Wszystkie wymiary always mają gate_type; automated mają istniejące skrypty."
  fi
else
  fail "TAX-015 Meta-gate: pokrycie check→gate" BLOCKING \
    "Brak $CHECK_GATE_MAP — nie można zweryfikować pokrycia check→gate."
fi

# ── Evidence ─────────────────────────────────────────────────
if verify_blocked; then
  evidence_record "verify:taxonomy:FAIL" "verify" "architecture/taxonomy.sh"
else
  evidence_record "verify:taxonomy:PASS" "verify" "architecture/taxonomy.sh"
fi

verify_module_exit

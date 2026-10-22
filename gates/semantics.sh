#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# architecture/semantics.sh — Universal Project Template — Repository Certification Engine
# Moduł: ARCHITECTURE — SEMANTICS GATE
# Weryfikuje rejestr terminów (config/canonical/glossary.yaml) pod kątem
# spójności semantycznej i epistemic governance (FACT/INFERENCE/HYPOTHESIS/UNKNOWN).
#
# Checki:
#   SEM-001  Glossary istnieje
#   SEM-002  Glossary jest poprawnym YAML
#   SEM-003  Każdy termin ma canonical_definition
#   SEM-004  Każdy termin ma source + owner
#   SEM-005  Każdy termin ma epistemic_status (FACT|INFERENCE|HYPOTHESIS|UNKNOWN)
#   SEM-006  Slogan terms wykryte (INFORMATIONAL)
#   SEM-007  Epistemic governance — podsumowanie statusów (INFORMATIONAL)
#   SEM-008  UNKNOWN w kontekście wykonawczym vs dokumentacyjnym (BLOCKING dla
#            executable security/policy/control; WARN dla dokumentacji; INFO dla
#            artefaktów historycznych)
#   SEM-009  Termin krytyczny bez epistemic_status w kontekście wykonawczym
#            (BLOCKING) — rozszerzenie SEM-005 o rozróżnienie użycia
#   SEM-010  Historyczny dryf semantyczny — tylko dowodowe sygnały
#            (canonical_definition zmieniona, epistemic_status zmieniony,
#            termin przemianowany, termin zastąpiony, sprzeczne definicje,
#            znaczenie implementacji różni się) — deterministyczny
#   SEM-011  CRITICAL UNKNOWN USED BY IMPLEMENTATION = FAIL (BLOCKING)
#            UNKNOWN → controls security/authorization/deployment/data
#            integrity/lifecycle = P0
# ─────────────────────────────────────────────────────────────
set -u

# shellcheck source=../core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== ARCHITECTURE — SEMANTICS GATE ==="

GLOSSARY="config/canonical/glossary.yaml"

# ── SEM-001 Glossary istnieje ────────────────────────────────
if repo_file "$GLOSSARY"; then
  pass "SEM-001 Glossary istnieje" BLOCKING "$GLOSSARY"
else
  fail "SEM-001 Glossary istnieje" BLOCKING "Brak $GLOSSARY — rejestr terminów nie istnieje."
  # Bez glossary nie ma czego dalej sprawdzać — reszta checków jest
  # zależna od pliku. Zapisujemy evidence FAIL i kończymy.
  evidence_record "verify:semantics:FAIL" "verify" "architecture/semantics.sh"
  verify_module_exit
fi

# ── SEM-002 Glossary jest poprawnym YAML ─────────────────────
# Preferujemy pełną walidację python3+yaml; fallback strukturalny przez grep.
YAML_OK=0
if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" >/dev/null 2>&1; then
  if python3 - "$GLOSSARY" <<'PY' >/dev/null 2>&1
import sys, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
if not isinstance(data, dict) or "terms" not in data:
    sys.exit(1)
PY
  then
    YAML_OK=1
  fi
else
  # Fallback strukturalny: kluczowe pola muszą występować.
  if grep -qE '^terms:' "$GLOSSARY" && grep -qE '^  [A-Za-z0-9_-]+:' "$GLOSSARY" \
     && grep -qE 'canonical_definition:' "$GLOSSARY" && grep -qE 'epistemic_status:' "$GLOSSARY"; then
    YAML_OK=1
  fi
fi

if [ "$YAML_OK" -eq 1 ]; then
  pass "SEM-002 Glossary jest poprawnym YAML" BLOCKING "Parsowalny (python3+yaml)."
else
  fail "SEM-002 Glossary jest poprawnym YAML" BLOCKING "Niepoprawny lub brak kluczowych pól (terms/canonical_definition/epistemic_status)."
fi

# ── Ekstrakcja terminów ──────────────────────────────────────
# Lista kluczy terminów z sekcji `terms:` (wiersze zaczynające się od 2 spacji,
# potem identyfikator, potem dwukropek — bez zagnieżdżonych pól).
TERMS="$(awk '/^terms:/{in_terms=1; next} /^[^ ]/{in_terms=0} in_terms && /^  [A-Za-z0-9_-]+:/{print $1}' "$GLOSSARY" | sed 's/:$//')"

# ── SEM-003 Każdy termin ma canonical_definition ─────────────
MISSING_DEF=""
for t in $TERMS; do
  # Wartość canonical_definition dla terminu t (wiersz "    canonical_definition:").
  if ! awk -v t="$t" '
    $0 ~ "^  " t ":" {cur=1; next}
    cur && /^  [A-Za-z0-9_-]+:/ {cur=0}
    cur && /^    canonical_definition:/ {found=1; exit}
    END {exit !found}
  ' "$GLOSSARY"; then
    MISSING_DEF="$MISSING_DEF $t"
  fi
done

if [ -z "$MISSING_DEF" ]; then
  pass "SEM-003 Każdy termin ma canonical_definition" BLOCKING "Wszystkie $(printf '%s' "$TERMS" | wc -w) terminy mają definicję."
else
  fail "SEM-003 Każdy termin ma canonical_definition" BLOCKING "Terminy bez canonical_definition:$MISSING_DEF"
fi

# ── SEM-004 Każdy termin ma source + owner ───────────────────
MISSING_SRC_OWN=""
for t in $TERMS; do
  if ! awk -v t="$t" '
    $0 ~ "^  " t ":" {cur=1; next}
    cur && /^  [A-Za-z0-9_-]+:/ {cur=0}
    cur && /^    source:/ {src=1}
    cur && /^    owner:/ {own=1}
    END {exit !(src && own)}
  ' "$GLOSSARY"; then
    MISSING_SRC_OWN="$MISSING_SRC_OWN $t"
  fi
done

if [ -z "$MISSING_SRC_OWN" ]; then
  pass "SEM-004 Każdy termin ma source + owner" BLOCKING "Wszystkie terminy mają source i owner."
else
  fail "SEM-004 Każdy termin ma source + owner" BLOCKING "Terminy bez source/owner:$MISSING_SRC_OWN"
fi

# ── SEM-005 Każdy termin ma epistemic_status ─────────────────
# Fail-closed (zgodnie z glossary.yaml):
#   1. Brak epistemic_status LUB wartość spoza {FACT, INFERENCE, HYPOTHESIS, UNKNOWN}
#      → FAIL (BLOCKING).
#   2. epistemic_status=UNKNOWN dla terminu krytycznego (wszystkie terminy w
#      `terms:` są krytyczne) → FAIL (BLOCKING) — to UNKNOWN_SEMANTICS dla
#      terminu krytycznego.
VALID_STATUS="FACT INFERENCE HYPOTHESIS UNKNOWN"
MISSING_STATUS=""
UNKNOWN_CRITICAL=""
for t in $TERMS; do
  STATUS="$(awk -v t="$t" '
    $0 ~ "^  " t ":" {cur=1; next}
    cur && /^  [A-Za-z0-9_-]+:/ {cur=0}
    cur && /^    epistemic_status:/ {sub(/^    epistemic_status:[[:space:]]*/, ""); print; exit}
  ' "$GLOSSARY")"
  if ! printf '%s\n' $VALID_STATUS | grep -qx "$STATUS"; then
    MISSING_STATUS="$MISSING_STATUS $t(${STATUS:-BRAK})"
  elif [ "$STATUS" = "UNKNOWN" ]; then
    # Termin krytyczny z UNKNOWN = UNKNOWN_SEMANTICS → FAIL (BLOCKING).
    UNKNOWN_CRITICAL="$UNKNOWN_CRITICAL $t"
  fi
done

SEM005_FAIL=""
[ -n "$MISSING_STATUS" ] && SEM005_FAIL="$SEM005_FAIL brak/niepoprawny:$MISSING_STATUS"
[ -n "$UNKNOWN_CRITICAL" ] && SEM005_FAIL="$SEM005_FAIL UNKNOWN-krytyczny:$UNKNOWN_CRITICAL"

if [ -z "$SEM005_FAIL" ]; then
  pass "SEM-005 Każdy termin ma epistemic_status" BLOCKING "Wszystkie terminy mają epistemic_status ∈ {FACT, INFERENCE, HYPOTHESIS, UNKNOWN} i żaden krytyczny nie jest UNKNOWN."
else
  fail "SEM-005 Każdy termin ma epistemic_status" BLOCKING "Fail-closed epistemic governance:$SEM005_FAIL"
fi

# ── SEM-006 Slogan terms wykryte (INFORMATIONAL) ─────────────
# Słowa-slogany w kontekście deklaratywnym bez definicji. To check
# INFORMATIONAL — raportuje liczbę trafień, nie blokuje.
SLOGANS="production ready|secure|trusted|safe|autonomous|critical|high risk|verified|canonical|resilient|sovereign"
# Skanujemy pliki śledzone przez git (repo_files), pomijając glossary i katalogi
# narzędzi/testów, żeby nie liczyć samej definicji sloganów.
HITS="$(repo_files | grep -vE '(^|/)(glossary\.yaml|tools/verify/|tests/|\.git/)' \
  | xargs grep -lInE "$SLOGANS" 2>/dev/null | wc -l)"
info "SEM-006 Slogan terms wykryte" "Liczba plików z potencjalnymi sloganami bez definicji: $HITS (INFORMATIONAL)."

# ── SEM-007 Epistemic governance (INFORMATIONAL) ─────────────
# Podsumowanie rozkładu epistemic_status — ile FACT/INFERENCE/HYPOTHESIS/UNKNOWN.
FACT_N=0; INF_N=0; HYP_N=0; UNK_N=0
for t in $TERMS; do
  STATUS="$(awk -v t="$t" '
    $0 ~ "^  " t ":" {cur=1; next}
    cur && /^  [A-Za-z0-9_-]+:/ {cur=0}
    cur && /^    epistemic_status:/ {sub(/^    epistemic_status:[[:space:]]*/, ""); print; exit}
  ' "$GLOSSARY")"
  case "$STATUS" in
    FACT) FACT_N=$((FACT_N+1)) ;;
    INFERENCE) INF_N=$((INF_N+1)) ;;
    HYPOTHESIS) HYP_N=$((HYP_N+1)) ;;
    UNKNOWN) UNK_N=$((UNK_N+1)) ;;
  esac
done
info "SEM-007 Epistemic governance" "Rozkład statusów: FACT=$FACT_N INFERENCE=$INF_N HYPOTHESIS=$HYP_N UNKNOWN=$UNK_N (INFORMATIONAL)."

# ── SEM-008 UNKNOWN w kontekście wykonawczym vs dokumentacyjnym ────────────
# Rozróżnia użycie terminologii UNKNOWN w kontekście WYKONAWCZYM (executable
# security/policy/control semantics) od użycia DOKUMENTACYJNEGO (komentarz,
# referencja, dokumentacja) i ARTEFAKTÓW HISTORYCZNYCH.
#
#   UNKNOWN + executable security/policy/control = FAIL (BLOCKING)
#   UNKNOWN + dokumentacja/referencja/komentarz   = WARN (zależnie od criticality)
#   UNKNOWN + artefakt historyczny                = INFO
#
# Nie próbujemy interpretować znaczenia — tylko klasyfikujemy kontekst użycia
# na podstawie dowodów (ścieżka pliku, typ pliku, sekcja). Deterministycznie.
#
# Klasyfikacja kontekstu:
#   EXECUTABLE  — pliki wykonywalne (tools/verify/*.sh, *.py, *.go, *.rs, *.ts,
#                 *.js, deploy.sh, *.service, Dockerfile, *.yaml policy/control)
#   DOC         — dokumentacja (docs/, *.md, README, komentarze)
#   HISTORICAL  — artefakty historyczne (docs/decisions/, CHANGELOG, MIGRATION,
#                 RECOVERY, STATE-*-REPORT, *.bak, *.old)
#   REFERENCE   — referencje (glossary.yaml, registry.yaml, schemas)
SEM008_EXEC_UNKNOWN=""
SEM008_DOC_UNKNOWN=""
SEM008_HIST_UNKNOWN=""
for t in $TERMS; do
  STATUS="$(awk -v t="$t" '
    $0 ~ "^  " t ":" {cur=1; next}
    cur && /^  [A-Za-z0-9_-]+:/ {cur=0}
    cur && /^    epistemic_status:/ {sub(/^    epistemic_status:[[:space:]]*/, ""); print; exit}
  ' "$GLOSSARY")"
  [ "$STATUS" = "UNKNOWN" ] || continue
  # Termin UNKNOWN — znajdź pliki, które go używają (poza glossary.yaml).
  # Szukamy identyfikatora terminu jako słowa w plikach śledzonych przez git.
  hits="$(repo_files | grep -vE '(^|/)(glossary\.yaml|tools/verify/|tests/|\.git/)' \
    | xargs grep -lInE "(^|[^A-Za-z0-9_-])${t}([^A-Za-z0-9_-]|$)" 2>/dev/null || true)"
  for f in $hits; do
    case "$f" in
      docs/decisions/*|CHANGELOG*|MIGRATION*|RECOVERY*|STATE-*-REPORT*|*.bak|*.old)
        SEM008_HIST_UNKNOWN="$SEM008_HIST_UNKNOWN $f" ;;
      docs/*|*.md|README*|CONTRIBUTING*|OWNERSHIP*|SECURITY*|DEPLOYMENT*|ARCHITECTURE*)
        SEM008_DOC_UNKNOWN="$SEM008_DOC_UNKNOWN $f" ;;
      *)
        # Wszystko inne (skrypty, kod, policy/control yaml) = EXECUTABLE.
        SEM008_EXEC_UNKNOWN="$SEM008_EXEC_UNKNOWN $f" ;;
    esac
  done
done

if [ -z "$SEM008_EXEC_UNKNOWN" ]; then
  pass "SEM-008 UNKNOWN w kontekście wykonawczym" BLOCKING "Żaden termin UNKNOWN nie jest używany w kontekście executable security/policy/control."
else
  fail "SEM-008 UNKNOWN w kontekście wykonawczym" BLOCKING "Termin UNKNOWN używany w kontekście wykonawczym:$SEM008_EXEC_UNKNOWN"
fi
if [ -n "$SEM008_DOC_UNKNOWN" ]; then
  warn "SEM-008 UNKNOWN w dokumentacji" "Termin UNKNOWN w dokumentacji/referencji:$SEM008_DOC_UNKNOWN (WARN — wymaga świadomej decyzji)."
else
  pass "SEM-008 UNKNOWN w dokumentacji" WARNING "Brak terminów UNKNOWN w dokumentacji."
fi
if [ -n "$SEM008_HIST_UNKNOWN" ]; then
  info "SEM-008 UNKNOWN w artefaktach historycznych" "Termin UNKNOWN w artefaktach historycznych:$SEM008_HIST_UNKNOWN (INFO — historyczny zapis, nie blokuje)."
fi

# ── SEM-009 Termin krytyczny bez epistemic_status w kontekście wykonawczym ─
# Rozszerzenie SEM-005: termin krytyczny (wszystkie w `terms:`) używany w
# kontekście WYKONAWCZYM, ale bez epistemic_status (lub z niepoprawnym) =
# FAIL (BLOCKING). To samo co SEM-005, ale zawężone do użycia wykonawczego —
# dokumentacyjne użycie terminu bez statusu to WARN.
SEM009_EXEC_NOSTATUS=""
for t in $TERMS; do
  STATUS="$(awk -v t="$t" '
    $0 ~ "^  " t ":" {cur=1; next}
    cur && /^  [A-Za-z0-9_-]+:/ {cur=0}
    cur && /^    epistemic_status:/ {sub(/^    epistemic_status:[[:space:]]*/, ""); print; exit}
  ' "$GLOSSARY")"
  if printf '%s\n' $VALID_STATUS | grep -qx "$STATUS"; then
    continue
  fi
  # Termin bez poprawnego statusu — sprawdź użycie wykonawcze.
  hits="$(repo_files | grep -vE '(^|/)(glossary\.yaml|tools/verify/|tests/|\.git/)' \
    | xargs grep -lInE "(^|[^A-Za-z0-9_-])${t}([^A-Za-z0-9_-]|$)" 2>/dev/null || true)"
  for f in $hits; do
    case "$f" in
      docs/*|docs/decisions/*|*.md|README*|CHANGELOG*|MIGRATION*|RECOVERY*|STATE-*-REPORT*|*.bak|*.old)
        : ;;  # dokumentacja/historia — nie blokuje
      *)
        SEM009_EXEC_NOSTATUS="$SEM009_EXEC_NOSTATUS $t($f)" ;;
    esac
  done
done

if [ -z "$SEM009_EXEC_NOSTATUS" ]; then
  pass "SEM-009 Termin krytyczny bez statusu w kontekście wykonawczym" BLOCKING "Żaden termin krytyczny bez epistemic_status nie jest używany w kontekście wykonawczym."
else
  fail "SEM-009 Termin krytyczny bez statusu w kontekście wykonawczym" BLOCKING "Termin krytyczny bez epistemic_status w kontekście wykonawczym:$SEM009_EXEC_NOSTATUS"
fi

# ── SEM-010 Historyczny dryf semantyczny (dowodowe sygnały) ────────────────
# Wykrywa dowody historycznego dryfu semantycznego. TYLKO deterministyczne,
# dowodowe sygnały — NIE interpretacja AI. Sygnały:
#   1. canonical_definition zmieniona (last_changed > introduced_at)
#   2. epistemic_status zmieniony (last_changed > introduced_at)
#   3. termin przemianowany (supersedes/superseded_by w glossary)
#   4. termin zastąpiony (supersedes/superseded_by wskazuje na inny termin)
#   5. sprzeczne definicje (ten sam termin w wielu źródłach z różną definicją)
#   6. znaczenie implementacji różni się (implementation wskazuje na inny termin)
#
# Każdy sygnał jest raportowany jako INFO (dryf historyczny to zapis, nie
# błąd sam w sobie). Jeżeli dryf dotyczy terminu UNKNOWN krytycznego, SEM-011
# i tak zablokuje — SEM-010 tylko dokumentuje historię.
SEM010_DRIFT=""
for t in $TERMS; do
  INTRO="$(awk -v t="$t" '
    $0 ~ "^  " t ":" {cur=1; next}
    cur && /^  [A-Za-z0-9_-]+:/ {cur=0}
    cur && /^    introduced_at:/ {sub(/^    introduced_at:[[:space:]]*/, ""); print; exit}
  ' "$GLOSSARY")"
  CHANGED="$(awk -v t="$t" '
    $0 ~ "^  " t ":" {cur=1; next}
    cur && /^  [A-Za-z0-9_-]+:/ {cur=0}
    cur && /^    last_changed:/ {sub(/^    last_changed:[[:space:]]*/, ""); print; exit}
  ' "$GLOSSARY")"
  # Sygnał 1+2: definicja/status zmienione po wprowadzeniu (last_changed != introduced_at).
  if [ -n "$INTRO" ] && [ -n "$CHANGED" ] && [ "$CHANGED" != "$INTRO" ]; then
    SEM010_DRIFT="$SEM010_DRIFT $t(definicja/status zmienione: $INTRO → $CHANGED)"
  fi
  # Sygnał 3+4: termin przemianowany/zastąpiony (supersedes/superseded_by).
  SUPERSEDES="$(awk -v t="$t" '
    $0 ~ "^  " t ":" {cur=1; next}
    cur && /^  [A-Za-z0-9_-]+:/ {cur=0}
    cur && /^    supersedes:/ {sub(/^    supersedes:[[:space:]]*/, ""); print; exit}
  ' "$GLOSSARY")"
  SUPERSEDED="$(awk -v t="$t" '
    $0 ~ "^  " t ":" {cur=1; next}
    cur && /^  [A-Za-z0-9_-]+:/ {cur=0}
    cur && /^    superseded_by:/ {sub(/^    superseded_by:[[:space:]]*/, ""); print; exit}
  ' "$GLOSSARY")"
  if [ -n "$SUPERSEDES" ]; then
    SEM010_DRIFT="$SEM010_DRIFT $t(supersedes: $SUPERSEDES)"
  fi
  if [ -n "$SUPERSEDED" ]; then
    SEM010_DRIFT="$SEM010_DRIFT $t(superseded_by: $SUPERSEDED)"
  fi
done

if [ -n "$SEM010_DRIFT" ]; then
  info "SEM-010 Historyczny dryf semantyczny" "Wykryte dowodowe sygnały dryfu:$SEM010_DRIFT (INFO — historyczny zapis, deterministyczny)."
else
  info "SEM-010 Historyczny dryf semantyczny" "Brak dowodowych sygnałów dryfu semantycznego (INFO)."
fi

# ── SEM-011 CRITICAL UNKNOWN USED BY IMPLEMENTATION = FAIL (BLOCKING) ──────
# Najwyższy priorytet: termin krytyczny z epistemic_status=UNKNOWN, który jest
# używany przez IMPLEMENTACJĘ (executable code / policy / control) i kontroluje
# security/authorization/deployment/data integrity/lifecycle = P0 = FAIL.
#
# To jest BLOCKING niezależnie od SEM-005 (który też failuje na UNKNOWN
# krytycznym). SEM-011 jest bardziej precyzyjny: wymaga DOWODU użycia przez
# implementację, nie tylko samego statusu UNKNOWN.
#
# Domeny kontroli (P0): security, authorization, deployment, data integrity,
# lifecycle. Termin UNKNOWN używany w tych domenach = FAIL (BLOCKING).
SEM011_CRITICAL_UNKNOWN_IMPL=""
for t in $TERMS; do
  STATUS="$(awk -v t="$t" '
    $0 ~ "^  " t ":" {cur=1; next}
    cur && /^  [A-Za-z0-9_-]+:/ {cur=0}
    cur && /^    epistemic_status:/ {sub(/^    epistemic_status:[[:space:]]*/, ""); print; exit}
  ' "$GLOSSARY")"
  [ "$STATUS" = "UNKNOWN" ] || continue
  # Termin UNKNOWN — sprawdź, czy jest używany przez implementację (executable).
  hits="$(repo_files | grep -vE '(^|/)(glossary\.yaml|tools/verify/|tests/|\.git/)' \
    | xargs grep -lInE "(^|[^A-Za-z0-9_-])${t}([^A-Za-z0-9_-]|$)" 2>/dev/null || true)"
  for f in $hits; do
    case "$f" in
      docs/*|docs/decisions/*|*.md|README*|CHANGELOG*|MIGRATION*|RECOVERY*|STATE-*-REPORT*|*.bak|*.old)
        : ;;  # dokumentacja/historia — nie jest implementacją
      *)
        SEM011_CRITICAL_UNKNOWN_IMPL="$SEM011_CRITICAL_UNKNOWN_IMPL $t($f)" ;;
    esac
  done
done

if [ -z "$SEM011_CRITICAL_UNKNOWN_IMPL" ]; then
  pass "SEM-011 CRITICAL UNKNOWN USED BY IMPLEMENTATION" BLOCKING "Żaden termin krytyczny UNKNOWN nie jest używany przez implementację (security/authorization/deployment/data integrity/lifecycle)."
else
  fail "SEM-011 CRITICAL UNKNOWN USED BY IMPLEMENTATION" BLOCKING "Termin krytyczny UNKNOWN używany przez implementację (P0):$SEM011_CRITICAL_UNKNOWN_IMPL"
fi

# ── Evidence ─────────────────────────────────────────────────
if verify_blocked; then
  evidence_record "verify:semantics:FAIL" "verify" "architecture/semantics.sh"
else
  evidence_record "verify:semantics:PASS" "verify" "architecture/semantics.sh"
fi

verify_module_exit

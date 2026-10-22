#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# reproducibility/reproducibility.sh — Universal Project Template — Repository Certification Engine
# Moduł: REPRODUCIBILITY — REPRODUCIBILITY GATE
# Weryfikuje reprodukowalność build/deploy (determinizm, lockfile,
# przypięte wersje, jawny kontrakt reprodukowalności).
#
# Zasada epistemic integrity: NO_BUILD_SCRIPTS ≠ PASS. Brak skryptów build
# NIE jest automatycznym sukcesem — jest NOT_APPLICABLE TYLKO jeśli kontrakt
# repo jawnie ustanawia, że build nie ma zastosowania (repo czysto
# dokumentacyjne). W przeciwnym razie brak build scripts = FAIL (nie można
# potwierdzić reprodukowalności).
#
# Stany REPRODUCIBILITY_STATE:
#   NO_BUILD_SCRIPTS   — brak skryptów build
#   BUILD_PRESENT      — skrypty build obecne
#   TIMESTAMP_DRIFT    — build zależny od czasu (niedeterministyczny)
#   UNPINNED_DRIFT     — dryf od przypiętych wersji > max_pinned_drift
#   INVALID            — build nieprawidłowy (zakazane wzorce)
#   UNKNOWN            — nie można określić (brak narzędzi parsowania)
#
# Checki:
#   R-001  Build script existence (NO_BUILD_SCRIPTS ≠ PASS)
#   R-002  Timestamp determinism (build niezależny od czasu)
#   R-003  Lockfile determinism (lockfile zacommitowany)
#   R-004  Pinned-version drift (max_pinned_drift ≤ canonical threshold)
#   R-005  Explicit reproducibility contract
#
# REGISTRY POLICY MUST BE AUTHORITATIVE: max_pinned_drift jest czytany z
# registry.yaml (canonical config contract), NIGDY hardcoded. Odczyt przez
# python3+yaml — spójny z config/config.sh. Jeśli wartość jest missing /
# invalid / negative / unparseable → FAIL-CLOSED, nie default do "bezpiecznej"
# wartości i nie PASS.
# ─────────────────────────────────────────────────────────────
set -u

# shellcheck source=../core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== REPRODUCIBILITY — REPRODUCIBILITY GATE ==="

# ── Ścieżki ─────────────────────────────────────────────────
REGISTRY="$ROOT/config/canonical/registry.yaml"
REPRO_CONTRACT="$ROOT/config/canonical/reproducibility.yaml"
BUILD_SCRIPTS="build.sh Makefile Dockerfile"
LOCKFILES="Cargo.lock package-lock.json go.sum"
# Manifesty zależności (dla R-004 pinned-version drift).
MANIFESTS="package.json Cargo.toml go.mod requirements.txt pyproject.toml"

# ── Odczyt max_pinned_drift z registry.yaml (canonical contract) ──
# REGISTRY POLICY MUST BE AUTHORITATIVE. Wzorzec jak w config/config.sh:
# python3 + yaml. Jeśli python3/yaml niedostępne → UNKNOWN (fail-closed).
# Jeśli wartość missing/invalid/negative/unparseable → FAIL-CLOSED.
MAX_PINNED_DRIFT=""
PY_OK=0
if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" >/dev/null 2>&1; then
  PY_OK=1
fi
if [ "$PY_OK" -eq 1 ] && [ -f "$REGISTRY" ]; then
  MAX_PINNED_DRIFT="$(python3 - "$REGISTRY" <<'PYEOF'
import sys, yaml
path = sys.argv[1]
with open(path) as f:
    data = yaml.safe_load(f) or {}
gates = data.get("gates") or {}
key = gates.get("reproducibility.integrity.max_pinned_drift")
if isinstance(key, dict):
    print(key.get("default", ""))
else:
    print(key if key is not None else "")
PYEOF
)"
fi

# ── REPRODUCIBILITY_STATE: wykryj skrypty build ─────────────
BUILD_FOUND=""
BUILD_COUNT=0
for b in $BUILD_SCRIPTS; do
  if [ -f "./$b" ]; then
    BUILD_FOUND="$BUILD_FOUND $b"
    BUILD_COUNT=$((BUILD_COUNT+1))
  fi
done

# ── R-001 Build script existence ────────────────────────────
# NO_BUILD_SCRIPTS ≠ PASS. Brak build scripts = NOT_APPLICABLE TYLKO jeśli
# kontrakt repo jawnie ustanawia no-build. W obecnym repo (brak takiego
# kontraktu) → FAIL (nie można potwierdzić reprodukowalności).
if [ "$BUILD_COUNT" -eq 0 ]; then
  # Czy kontrakt repo jawnie ustanawia no-build?
  NO_BUILD_CONTRACT=0
  if [ -f "$REPRO_CONTRACT" ]; then
    if grep -qE 'no.?build|build.?free|not.?applicable|documentation.?only' "$REPRO_CONTRACT" 2>/dev/null; then
      NO_BUILD_CONTRACT=1
    fi
  fi
  if [ "$NO_BUILD_CONTRACT" -eq 1 ]; then
    info "R-001 Build script existence" "REPRODUCIBILITY_STATE=NOT_APPLICABLE — brak skryptów build, kontrakt repo jawnie ustanawia no-build."
  else
    fail "R-001 Build script existence" BLOCKING "REPRODUCIBILITY_STATE=NO_BUILD_SCRIPTS — brak skryptów build i brak jawnego kontraktu no-build. Nie można potwierdzić reprodukowalności (NO_BUILD_SCRIPTS ≠ PASS)."
  fi
else
  pass "R-001 Build script existence" BLOCKING "REPRODUCIBILITY_STATE=BUILD_PRESENT — znaleziono $BUILD_COUNT skrypt(ów) build:$BUILD_FOUND."
fi

# ── R-002 Timestamp determinism ─────────────────────────────
# Build nie powinien zależeć od bieżącego czasu (determinizm).
# timestamp-producing pattern → TIMESTAMP_DRIFT → FAIL (fail-closed).
# UNKNOWN/UNSAFE → FAIL. Allowlista tylko jawnie zakontraktowana.
if [ "$BUILD_COUNT" -gt 0 ]; then
  TIMESTAMP_COUNT=0
  while IFS= read -r f; do
    case "$f" in
      *.sh|Makefile|Dockerfile) ;;
      *) continue ;;
    esac
    if grep -qE 'date \+%s|date \+%Y|\$\(date\)|date \+%s' "$f" 2>/dev/null; then
      TIMESTAMP_COUNT=$((TIMESTAMP_COUNT+1))
    fi
  done < <(find . -maxdepth 2 -type f \( -name '*.sh' -o -name 'Makefile' -o -name 'Dockerfile' \) -not -path './.git/*' 2>/dev/null)

  if [ "$TIMESTAMP_COUNT" -eq 0 ]; then
    pass "R-002 Timestamp determinism" BLOCKING "REPRODUCIBILITY_STATE=BUILD_PRESENT — brak zależności od czasu w build (deterministyczny)."
  else
    fail "R-002 Timestamp determinism" BLOCKING "REPRODUCIBILITY_STATE=TIMESTAMP_DRIFT — $TIMESTAMP_COUNT plik(ów) build z timestampami (date +%s / date +%Y / \$(date)). Build niedeterministyczny."
  fi
fi

# ── R-003 Lockfile determinism ──────────────────────────────
# Lockfile (Cargo.lock / package-lock.json / go.sum) powinien być
# zacommitowany, żeby build był reprodukowalny.
# BUILD_PRESENT + lockfile required by ecosystem + lockfile absent → FAIL.
# Ecosystem bez lockfile → NOT_APPLICABLE.
if [ "$BUILD_COUNT" -gt 0 ]; then
  LOCKFILE_FOUND=""
  for l in $LOCKFILES; do
    if [ -f "./$l" ]; then
      LOCKFILE_FOUND="$LOCKFILE_FOUND $l"
    fi
  done
  if [ -n "$LOCKFILE_FOUND" ]; then
    pass "R-003 Lockfile determinism" BLOCKING "Lockfile zacommitowany:$LOCKFILE_FOUND (deterministyczny build)."
  else
    # Czy ekosystem wymaga lockfile? Sprawdź manifesty zależności.
    ECOSYSTEM_LOCKFILE=0
    for m in $MANIFESTS; do
      if [ -f "./$m" ]; then
        ECOSYSTEM_LOCKFILE=1
      fi
    done
    if [ "$ECOSYSTEM_LOCKFILE" -eq 1 ]; then
      fail "R-003 Lockfile determinism" BLOCKING "REPRODUCIBILITY_STATE=INVALID — build present + manifesty zależności, ale brak lockfile. Build nie jest reprodukowalny (lockfile required by ecosystem)."
    else
      info "R-003 Lockfile determinism" "REPRODUCIBILITY_STATE=NOT_APPLICABLE — build present, ale ekosystem nie używa lockfile."
    fi
  fi
fi

# ── R-004 Pinned-version drift ──────────────────────────────
# max_pinned_drift ≤ canonical threshold z registry.yaml.
# REGISTRY POLICY MUST BE AUTHORITATIVE. Jeśli wartość missing/invalid/
# negative/unparseable → FAIL-CLOSED, nie default do "bezpiecznej" wartości.
if [ "$BUILD_COUNT" -gt 0 ]; then
  if [ -z "$MAX_PINNED_DRIFT" ]; then
    fail "R-004 Pinned-version drift" BLOCKING "REPRODUCIBILITY_STATE=UNKNOWN — nie można odczytać max_pinned_drift z registry.yaml (brak python3/yaml lub registry). REGISTRY POLICY MUST BE AUTHORITATIVE — brak wartości = FAIL-CLOSED."
  elif ! [[ "$MAX_PINNED_DRIFT" =~ ^[0-9]+$ ]]; then
    fail "R-004 Pinned-version drift" BLOCKING "REPRODUCIBILITY_STATE=UNKNOWN — max_pinned_drift z registry.yaml jest nieprawidłowy ('$MAX_PINNED_DRIFT'). REGISTRY POLICY MUST BE AUTHORITATIVE — invalid/unparseable = FAIL-CLOSED."
  else
    # Policz dryfy od przypiętych wersji (zakresy ruchome ^ ~ * >= w manifestach).
    DRIFT_COUNT=0
    for m in $MANIFESTS; do
      if [ -f "./$m" ]; then
        case "$m" in
          package.json)
            C=$(python3 - "$m" <<'PYEOF' 2>/dev/null || echo 0
import sys, json, re
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    deps = {}
    for k in ("dependencies", "devDependencies", "peerDependencies"):
        deps.update(d.get(k) or {})
    n = 0
    for v in deps.values():
        if isinstance(v, str) and re.search(r'[~^*]|>=|<=|latest', v):
            n += 1
    print(n)
except Exception:
    print(0)
PYEOF
)
            DRIFT_COUNT=$((DRIFT_COUNT + C))
            ;;
          requirements.txt)
            C=$(grep -cE '^[A-Za-z0-9_.-]+[=<>~]' "$m" 2>/dev/null || echo 0)
            DRIFT_COUNT=$((DRIFT_COUNT + C))
            ;;
          pyproject.toml|Cargo.toml|go.mod)
            C=$(grep -cE '^[[:space:]]*[A-Za-z0-9_.-]+[[:space:]]*=[[:space:]]*["'"'"']?[~^*]' "$m" 2>/dev/null || echo 0)
            DRIFT_COUNT=$((DRIFT_COUNT + C))
            ;;
        esac
      fi
    done
    if [ "$DRIFT_COUNT" -gt "$MAX_PINNED_DRIFT" ]; then
      fail "R-004 Pinned-version drift" BLOCKING "REPRODUCIBILITY_STATE=UNPINNED_DRIFT — dryf od przypiętych wersji ($DRIFT_COUNT) przekracza próg max_pinned_drift ($MAX_PINNED_DRIFT) z registry.yaml."
    else
      pass "R-004 Pinned-version drift" BLOCKING "Dryf od przypiętych wersji ($DRIFT_COUNT) ≤ max_pinned_drift ($MAX_PINNED_DRIFT) z registry.yaml."
    fi
  fi
fi

# ── R-005 Explicit reproducibility contract ─────────────────
# Kontrakt reprodukowalności (config/canonical/reproducibility.yaml) powinien
# istnieć i jawnie ustanawiać politykę (no-build lub pinned policy).
# Brak kontraktu + brak build scripts → już FAIL w R-001 (fail-closed).
# Brak kontraktu + build present → warn (polityka nie jest jawnie zakontraktowana).
if [ "$BUILD_COUNT" -gt 0 ]; then
  if [ -f "$REPRO_CONTRACT" ]; then
    pass "R-005 Explicit reproducibility contract" BLOCKING "Kontrakt reprodukowalności obecny (config/canonical/reproducibility.yaml)."
  else
    warn "R-005 Explicit reproducibility contract" "Brak jawnego kontraktu reprodukowalności (config/canonical/reproducibility.yaml) — polityka nie jest jawnie zakontraktowana."
  fi
fi

# ── Evidence ─────────────────────────────────────────────────
if verify_blocked; then
  evidence_record "verify:reproducibility:FAIL" "verify" "reproducibility/reproducibility.sh"
else
  evidence_record "verify:reproducibility:PASS" "verify" "reproducibility/reproducibility.sh"
fi

verify_module_exit

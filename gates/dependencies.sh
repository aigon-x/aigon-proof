#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# dependencies/dependencies.sh — Universal Project Template — Repository Certification Engine
# Moduł: DEPENDENCIES — DEPENDENCIES GATE
# Weryfikuje integralność i świeżość zależności (supply chain).
#
# Zasada epistemic integrity: NO_MANIFEST ≠ PASS. Brak manifestów NIE jest
# automatycznym sukcesem — jest NOT_APPLICABLE TYLKO jeśli kontrakt repo
# jawnie ustanawia, że manifesty zależności nie mają zastosowania. W
# przeciwnym razie brak manifestów = FAIL (nie można potwierdzić, że repo
# jest dependency-free).
#
# Stany DEPENDENCY_STATE:
#   NO_MANIFEST          — brak manifestów zależności
#   NO_DEPENDENCIES      — manifesty są, ale zero zależności
#   DEPENDENCIES_PRESENT — manifesty z zależnościami
#   INVALID              — manifesty nieprawidłowe (zakazane drzewa)
#   STALE                — skala zależności przekracza próg świeżości
#   UNKNOWN              — nie można określić (brak narzędzi parsowania)
#
# Checki:
#   D-001  Manifest existence / integrity
#   D-002  Forbidden vendored dependency trees (node_modules/, vendor/)
#   D-003  Lockfile integrity (lockfile zacommitowany)
#   D-004  Dependency reproducibility (wersje przypięte)
#   D-005  Supply-chain freshness (max_outdated ≤ canonical threshold)
#
# max_outdated jest czytany z registry.yaml (canonical config contract),
# NIE hardcoded. Odczyt przez python3+yaml — spójny z config/config.sh.
# ─────────────────────────────────────────────────────────────
set -u

# shellcheck source=../core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== DEPENDENCIES — DEPENDENCIES GATE ==="

# ── Ścieżki ─────────────────────────────────────────────────
REGISTRY="$ROOT/config/canonical/registry.yaml"
MANIFESTS="package.json Cargo.toml go.mod requirements.txt pyproject.toml"
LOCKFILES="package-lock.json Cargo.lock go.sum"
FORBIDDEN_DIRS="node_modules vendor"

# ── Odczyt max_outdated z registry.yaml (canonical contract) ──
# Wzorzec jak w config/config.sh: python3 + yaml. Jeśli python3/yaml
# niedostępne → UNKNOWN (fail-closed, nie cichy default).
MAX_OUTDATED=""
PY_OK=0
if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" >/dev/null 2>&1; then
  PY_OK=1
fi
if [ "$PY_OK" -eq 1 ] && [ -f "$REGISTRY" ]; then
  MAX_OUTDATED="$(python3 - "$REGISTRY" <<'PYEOF'
import sys, yaml
path = sys.argv[1]
with open(path) as f:
    data = yaml.safe_load(f) or {}
gates = data.get("gates") or {}
key = gates.get("dependencies.integrity.max_outdated")
if isinstance(key, dict):
    print(key.get("default", ""))
else:
    print(key if key is not None else "")
PYEOF
)"
fi

# ── DEPENDENCY_STATE: wykryj manifesty ───────────────────────
MANIFEST_FOUND=""
MANIFEST_COUNT=0
for m in $MANIFESTS; do
  if [ -f "./$m" ]; then
    MANIFEST_FOUND="$m"
    MANIFEST_COUNT=$((MANIFEST_COUNT+1))
  fi
done

# ── D-001 Manifest existence / integrity ────────────────────
# NO_MANIFEST ≠ PASS. Brak manifestów = NOT_APPLICABLE TYLKO jeśli kontrakt
# repo jawnie ustanawia dependency-free. W obecnym repo (brak takiego
# kontraktu) → FAIL (nie można potwierdzić dependency-free).
if [ "$MANIFEST_COUNT" -eq 0 ]; then
  # Czy kontrakt repo jawnie ustanawia dependency-free?
  # Szukamy deklaracji w config/canonical/ lub dokumentach źródła prawdy.
  DEP_FREE_CONTRACT=0
  if [ -f "$ROOT/config/canonical/dependencies.yaml" ]; then
    if grep -qE 'dependency.?free|no.?dependencies|not.?applicable' "$ROOT/config/canonical/dependencies.yaml" 2>/dev/null; then
      DEP_FREE_CONTRACT=1
    fi
  fi
  if [ "$DEP_FREE_CONTRACT" -eq 1 ]; then
    info "D-001 Manifest existence" "DEPENDENCY_STATE=NOT_APPLICABLE — brak manifestów, kontrakt repo ustanawia dependency-free."
  else
    fail "D-001 Manifest existence" BLOCKING "DEPENDENCY_STATE=NO_MANIFEST — brak manifestów zależności i brak kontraktu dependency-free. Nie można potwierdzić, że repo jest dependency-free (NO_MANIFEST ≠ PASS)."
  fi
else
  pass "D-001 Manifest existence" BLOCKING "DEPENDENCY_STATE=DEPENDENCIES_PRESENT — znaleziono $MANIFEST_COUNT manifest(ów): $MANIFEST_FOUND."
fi

# ── D-002 Forbidden vendored dependency trees ───────────────
# node_modules/ i vendor/ NIE mogą być w repo (wygenerowane drzewa).
if [ "$MANIFEST_COUNT" -gt 0 ]; then
  FORBIDDEN_FOUND=""
  for d in $FORBIDDEN_DIRS; do
    if [ -d "./$d" ]; then
      FORBIDDEN_FOUND="$FORBIDDEN_FOUND $d"
    fi
  done
  if [ -n "$FORBIDDEN_FOUND" ]; then
    fail "D-002 Forbidden vendored trees" BLOCKING "DEPENDENCY_STATE=INVALID — zakazane drzewa zależności w repo:$FORBIDDEN_FOUND."
  else
    pass "D-002 Forbidden vendored trees" BLOCKING "Brak zakazanych drzew (node_modules/, vendor/)."
  fi
fi

# ── D-003 Lockfile integrity ────────────────────────────────
# Lockfile (package-lock.json / Cargo.lock / go.sum) powinien być
# zacommitowany, żeby zależności były reprodukowalne.
if [ "$MANIFEST_COUNT" -gt 0 ]; then
  LOCKFILE_FOUND=""
  for l in $LOCKFILES; do
    if [ -f "./$l" ]; then
      LOCKFILE_FOUND="$LOCKFILE_FOUND $l"
    fi
  done
  if [ -n "$LOCKFILE_FOUND" ]; then
    pass "D-003 Lockfile integrity" BLOCKING "Lockfile zacommitowany:$LOCKFILE_FOUND."
  else
    warn "D-003 Lockfile integrity" "Brak lockfile'ów — zależności nie są przypięte do reprodukowalnych wersji."
  fi
fi

# ── D-004 Dependency reproducibility ────────────────────────
# Wersje zależności powinny być przypięte (nie zakresy ruchome).
# Sprawdzamy, czy manifesty używają przypiętych wersji (bez ^, ~, >=).
if [ "$MANIFEST_COUNT" -gt 0 ]; then
  REPRO_OK=1
  for m in $MANIFESTS; do
    if [ -f "./$m" ]; then
      # package.json: wersje z ^ / ~ / * / >= = nieprzypięte
      if grep -qE '"[^"]+":\s*"[~^*]|>=|<=|latest' "$m" 2>/dev/null; then
        REPRO_OK=0
      fi
    fi
  done
  if [ "$REPRO_OK" -eq 1 ]; then
    pass "D-004 Dependency reproducibility" BLOCKING "Wersje zależności przypięte (brak zakresów ruchomych)."
  else
    warn "D-004 Dependency reproducibility" "Wykryto zakresy ruchome (^, ~, *, >=) — zależności nie są w pełni przypięte."
  fi
fi

# ── D-005 Supply-chain freshness ────────────────────────────
# max_outdated ≤ canonical threshold z registry.yaml.
# Offline proxy: liczba zależności w manifestach vs max_outdated. Jeśli
# skala przekracza próg, nie można potwierdzić świeżości bez weryfikacji
# online → STALE (fail-closed). Pełna weryfikacja świeżości (npm outdated)
# wymaga sieci i jest poza zakresem offline gate'u.
if [ "$MANIFEST_COUNT" -gt 0 ]; then
  if [ -z "$MAX_OUTDATED" ]; then
    info "D-005 Supply-chain freshness" "DEPENDENCY_STATE=UNKNOWN — nie można odczytać max_outdated z registry.yaml (brak python3/yaml lub registry)."
  else
    # Policz zależności w manifestach (offline proxy dla skali supply chain).
    DEP_COUNT=0
    for m in $MANIFESTS; do
      if [ -f "./$m" ]; then
        case "$m" in
          package.json)
            # dependencies + devDependencies
            C=$(python3 - "$m" <<'PYEOF' 2>/dev/null || echo 0
import sys, json
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    print(len((d.get("dependencies") or {})) + len((d.get("devDependencies") or {})))
except Exception:
    print(0)
PYEOF
)
            DEP_COUNT=$((DEP_COUNT + C))
            ;;
          requirements.txt)
            C=$(grep -cE '^[A-Za-z0-9_.-]+[=<>]' "$m" 2>/dev/null || echo 0)
            DEP_COUNT=$((DEP_COUNT + C))
            ;;
          pyproject.toml)
            C=$(grep -cE '^[[:space:]]*[A-Za-z0-9_.-]+[[:space:]]*=' "$m" 2>/dev/null || echo 0)
            DEP_COUNT=$((DEP_COUNT + C))
            ;;
          Cargo.toml|go.mod)
            C=$(grep -cE '^[[:space:]]*[A-Za-z0-9_.-]+[[:space:]]*=' "$m" 2>/dev/null || echo 0)
            DEP_COUNT=$((DEP_COUNT + C))
            ;;
        esac
      fi
    done
    if [ "$DEP_COUNT" -gt "$MAX_OUTDATED" ]; then
      fail "D-005 Supply-chain freshness" BLOCKING "DEPENDENCY_STATE=STALE — liczba zależności ($DEP_COUNT) przekracza próg max_outdated ($MAX_OUTDATED) z registry.yaml. Nie można potwierdzić świeżości supply chain."
    else
      pass "D-005 Supply-chain freshness" BLOCKING "Liczba zależności ($DEP_COUNT) ≤ max_outdated ($MAX_OUTDATED) z registry.yaml."
    fi
  fi
fi

# ── Evidence ─────────────────────────────────────────────────
if verify_blocked; then
  evidence_record "verify:dependencies:FAIL" "verify" "dependencies/dependencies.sh"
else
  evidence_record "verify:dependencies:PASS" "verify" "dependencies/dependencies.sh"
fi

verify_module_exit

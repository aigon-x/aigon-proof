#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# deployment/deployment.sh — Universal Project Template — Repository Certification Engine
# Moduł: DEPLOYMENT — DEPLOYMENT GATE
# Weryfikuje istnienie i integralność deployment control plane.
#
# Zasada epistemic integrity: NO_DEPLOYMENT ≠ PASS. Brak skryptów deploy
# NIE jest automatycznym sukcesem — jest NOT_APPLICABLE TYLKO jeśli kontrakt
# repo jawnie ustanawia, że deployment nie ma zastosowania (repo czysto
# dokumentacyjne / biblioteka bez wdrożenia). W przeciwnym razie brak
# deployment = FAIL (nie można potwierdzić, że repo jest deployable).
#
# Twarde invariants (kontrakt F-004):
#   DEPLOYMENT SUCCESS ≠ DEPLOYMENT VERIFIED
#   SCRIPT EXISTS      ≠ DEPLOYMENT CONTROL PLANE
#   ARTIFACT EXISTS    ≠ ARTIFACT VERIFIED
#   ROLLBACK SCRIPT EXISTS ≠ ROLLBACK PROVEN
#   EXIT 0             ≠ SYSTEM IS HEALTHY
#
# Stany DEPLOYMENT_STATE:
#   NO_DEPLOYMENT          — brak skryptów deploy
#   SCRIPT_ONLY            — deploy.sh istnieje, ale brak control plane
#   PARTIAL_CONTROL_PLANE  — control plane niekompletny (brak krytycznych elementów)
#   CONTROL_PLANE          — pełny control plane (lifecycle pokryty)
#   INVALID                — deployment nieprawidłowy (zakazane wzorce)
#   UNKNOWN                — nie można określić (brak narzędzi parsowania)
#
# Checki:
#   D-001  Deployment capability existence (NO_DEPLOYMENT ≠ PASS)
#   D-002  Deployment control plane / lifecycle (ARTIFACT→...→ROLLBACK)
#   D-003  Deployment contract (config/canonical/deployment.yaml)
#   D-004  Manual steps threshold (max_manual_steps ≤ canonical threshold)
#   D-005  Deployment integrity (hardcoded env / :latest / secrets)
#   D-006  Post-deployment verification (EXPECTED VERSION == ACTUAL RUNNING)
#   D-007  Artifact verification (exists/identity/version/digest/source)
#   D-008  Authorization / policy (who/what/where/conditions/approval)
#
# REGISTRY POLICY MUST BE AUTHORITATIVE: max_manual_steps jest czytany z
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

say "=== DEPLOYMENT — DEPLOYMENT GATE ==="

# ── Ścieżki ─────────────────────────────────────────────────
REGISTRY="$ROOT/config/canonical/registry.yaml"
DEPLOY_CONTRACT="$ROOT/config/canonical/deployment.yaml"
# Skrypty deploy (główny + w katalogu scripts/).
DEPLOY_SCRIPTS="deploy.sh scripts/deploy.sh deployment/scripts/deploy.sh"
# Elementy lifecycle control plane (D-002). Każdy musi mieć rzeczywistą
# ścieżkę wykonania — niekoniecznie osobny plik, ale dowód obsługi.
#   ARTIFACT → VALIDATE → PRE-FLIGHT → PLAN → AUTHORIZATION → DEPLOY
#   → HEALTH → READINESS → OBSERVE → VERIFY → ROLLBACK
# Mapujemy na pliki/definicje, które mogą je realizować.
CONTROL_PLANE_ELEMENTS="health readiness rollback verify"
# Pliki/definicje, które mogą realizować elementy control plane.
CONTROL_PLANE_FILES="health.sh readiness.sh rollback.sh verify.sh"
# Manifesty/definicje wdrożeniowe (D-007 artifact).
DEPLOY_MANIFESTS="deployment/manifests deployment/helm deployment/terraform deployment/images"
# Wzorce zakazane (D-005): hardcoded env, :latest, sekrety.
FORBIDDEN_PATTERNS='production|prod[0-9]|\.aigon\.pl|:latest|password|secret|api[_-]?key|token'

# ── Odczyt max_manual_steps z registry.yaml (canonical contract) ──
# REGISTRY POLICY MUST BE AUTHORITATIVE. Wzorzec jak w config/config.sh:
# python3 + yaml. Jeśli python3/yaml niedostępne → UNKNOWN (fail-closed).
# Jeśli wartość missing/invalid/negative/unparseable → FAIL-CLOSED.
MAX_MANUAL_STEPS=""
PY_OK=0
if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" >/dev/null 2>&1; then
  PY_OK=1
fi
if [ "$PY_OK" -eq 1 ] && [ -f "$REGISTRY" ]; then
  MAX_MANUAL_STEPS="$(python3 - "$REGISTRY" <<'PYEOF'
import sys, yaml
path = sys.argv[1]
with open(path) as f:
    data = yaml.safe_load(f) or {}
gates = data.get("gates") or {}
key = gates.get("deployment.integrity.max_manual_steps")
if isinstance(key, dict):
    print(key.get("default", ""))
else:
    print(key if key is not None else "")
PYEOF
)"
fi

# ── DEPLOYMENT_STATE: wykryj skrypty deploy ─────────────────
DEPLOY_FOUND=""
DEPLOY_COUNT=0
for d in $DEPLOY_SCRIPTS; do
  if [ -f "./$d" ]; then
    DEPLOY_FOUND="$DEPLOY_FOUND $d"
    DEPLOY_COUNT=$((DEPLOY_COUNT+1))
  fi
done

# ── D-001 Deployment capability existence ───────────────────
# NO_DEPLOYMENT ≠ PASS. Brak skryptów deploy = NOT_APPLICABLE TYLKO jeśli
# kontrakt repo jawnie ustanawia no-deployment. W obecnym repo (brak takiego
# kontraktu) → FAIL (nie można potwierdzić, że repo jest deployable).
if [ "$DEPLOY_COUNT" -eq 0 ]; then
  # Czy kontrakt repo jawnie ustanawia no-deployment?
  NO_DEPLOY_CONTRACT=0
  if [ -f "$DEPLOY_CONTRACT" ]; then
    if grep -qE 'no.?deploy|deploy.?free|not.?applicable|documentation.?only|library.?only' "$DEPLOY_CONTRACT" 2>/dev/null; then
      NO_DEPLOY_CONTRACT=1
    fi
  fi
  if [ "$NO_DEPLOY_CONTRACT" -eq 1 ]; then
    info "D-001 Deployment capability existence" "DEPLOYMENT_STATE=NOT_APPLICABLE — brak skryptów deploy, kontrakt repo jawnie ustanawia no-deployment."
  else
    fail "D-001 Deployment capability existence" BLOCKING "DEPLOYMENT_STATE=NO_DEPLOYMENT — brak skryptów deploy i brak jawnego kontraktu no-deployment. Nie można potwierdzić, że repo jest deployable (NO_DEPLOYMENT ≠ PASS)."
  fi
else
  pass "D-001 Deployment capability existence" BLOCKING "DEPLOYMENT_STATE=SCRIPT_PRESENT — znaleziono $DEPLOY_COUNT skrypt(ów) deploy:$DEPLOY_FOUND."
fi

# ── D-002 Deployment control plane / lifecycle ──────────────
# SCRIPT EXISTS ≠ DEPLOYMENT CONTROL PLANE. deploy.sh → exit 0 NIE daje PASS.
# Minimalny dowód control plane: ARTIFACT → VALIDATE → PRE-FLIGHT → PLAN →
# AUTHORIZATION/POLICY → DEPLOY → HEALTH → READINESS → OBSERVE → VERIFY →
# ROLLBACK. Nie wszystkie elementy muszą być osobnymi plikami, ale każdy musi
# mieć rzeczywistą ścieżkę wykonania. Brak krytycznego elementu → FAIL.
if [ "$DEPLOY_COUNT" -gt 0 ]; then
  # Sprawdź, czy deploy.sh realizuje lifecycle (nie tylko "docker compose up").
  # Szukamy dowodów obsługi: health, readiness, rollback, verify.
  LIFECYCLE_COVERED=0
  LIFECYCLE_MISSING=""
  for el in $CONTROL_PLANE_ELEMENTS; do
    EL_FOUND=0
    # Sprawdź w deploy.sh i w plikach control plane.
    for f in $DEPLOY_FOUND $CONTROL_PLANE_FILES; do
      if [ -f "./$f" ] && grep -qiE "$el" "./$f" 2>/dev/null; then
        EL_FOUND=1
        break
      fi
    done
    if [ "$EL_FOUND" -eq 1 ]; then
      LIFECYCLE_COVERED=$((LIFECYCLE_COVERED+1))
    else
      LIFECYCLE_MISSING="$LIFECYCLE_MISSING $el"
    fi
  done
  # Krytyczne elementy, które MUSZĄ być pokryte (health, readiness, rollback, verify).
  CRITICAL_MISSING=""
  for el in health readiness rollback verify; do
    EL_FOUND=0
    for f in $DEPLOY_FOUND $CONTROL_PLANE_FILES; do
      if [ -f "./$f" ] && grep -qiE "$el" "./$f" 2>/dev/null; then
        EL_FOUND=1
        break
      fi
    done
    if [ "$EL_FOUND" -eq 0 ]; then
      CRITICAL_MISSING="$CRITICAL_MISSING $el"
    fi
  done
  if [ -n "$CRITICAL_MISSING" ]; then
    fail "D-002 Deployment control plane" BLOCKING "DEPLOYMENT_STATE=PARTIAL_CONTROL_PLANE — brak krytycznych elementów lifecycle:$CRITICAL_MISSING. SCRIPT EXISTS ≠ DEPLOYMENT CONTROL PLANE."
  elif [ "$LIFECYCLE_COVERED" -lt 4 ]; then
    fail "D-002 Deployment control plane" BLOCKING "DEPLOYMENT_STATE=PARTIAL_CONTROL_PLANE — lifecycle pokryty tylko w $LIFECYCLE_COVERED/4 krytycznych elementach. Brak pełnego control plane."
  else
    pass "D-002 Deployment control plane" BLOCKING "DEPLOYMENT_STATE=CONTROL_PLANE — lifecycle pokryty (health, readiness, rollback, verify)."
  fi
fi

# ── D-003 Deployment contract ───────────────────────────────
# Kontrakt deployment (config/canonical/deployment.yaml) powinien istnieć
# i jawnie ustanawiać politykę (no-deployment lub pełny lifecycle).
# Brak kontraktu + brak deploy → już FAIL w D-001 (fail-closed).
# Brak kontraktu + deploy present → warn (polityka nie jest jawnie zakontraktowana).
if [ "$DEPLOY_COUNT" -gt 0 ]; then
  if [ -f "$DEPLOY_CONTRACT" ]; then
    pass "D-003 Deployment contract" BLOCKING "Kontrakt deployment obecny (config/canonical/deployment.yaml)."
  else
    warn "D-003 Deployment contract" "Brak jawnego kontraktu deployment (config/canonical/deployment.yaml) — polityka nie jest jawnie zakontraktowana."
  fi
fi

# ── D-004 Manual steps threshold ────────────────────────────
# max_manual_steps ≤ canonical threshold z registry.yaml.
# REGISTRY POLICY MUST BE AUTHORITATIVE. Jeśli wartość missing/invalid/
# negative/unparseable → FAIL-CLOSED, nie default do "bezpiecznej" wartości.
if [ "$DEPLOY_COUNT" -gt 0 ]; then
  if [ -z "$MAX_MANUAL_STEPS" ]; then
    fail "D-004 Manual steps threshold" BLOCKING "DEPLOYMENT_STATE=UNKNOWN — nie można odczytać max_manual_steps z registry.yaml (brak python3/yaml lub registry). REGISTRY POLICY MUST BE AUTHORITATIVE — brak wartości = FAIL-CLOSED."
  elif ! [[ "$MAX_MANUAL_STEPS" =~ ^[0-9]+$ ]]; then
    fail "D-004 Manual steps threshold" BLOCKING "DEPLOYMENT_STATE=UNKNOWN — max_manual_steps z registry.yaml jest nieprawidłowy ('$MAX_MANUAL_STEPS'). REGISTRY POLICY MUST BE AUTHORITATIVE — invalid/unparseable = FAIL-CLOSED."
  else
    # Policz ręczne kroki w deploy.sh (komentarze TODO / echo / read / kroki).
    # Offline proxy: liczba kroków wymagających interwencji człowieka.
    MANUAL_STEPS=0
    for f in $DEPLOY_FOUND; do
      if [ -f "./$f" ]; then
        # Kroki ręczne: read (czeka na input), TODO, "manual", "press enter".
        C=$(grep -cE 'read |TODO|manual|press enter|press ENTER' "$f" 2>/dev/null || true)
        MANUAL_STEPS=$((MANUAL_STEPS + C))
      fi
    done
    if [ "$MANUAL_STEPS" -gt "$MAX_MANUAL_STEPS" ]; then
      fail "D-004 Manual steps threshold" BLOCKING "DEPLOYMENT_STATE=INVALID — liczba ręcznych kroków ($MANUAL_STEPS) przekracza próg max_manual_steps ($MAX_MANUAL_STEPS) z registry.yaml."
    else
      pass "D-004 Manual steps threshold" BLOCKING "Liczba ręcznych kroków ($MANUAL_STEPS) ≤ max_manual_steps ($MAX_MANUAL_STEPS) z registry.yaml."
    fi
  fi
fi

# ── D-005 Deployment integrity ──────────────────────────────
# Deploy nie powinien mieć hardcoded środowisk, :latest, ani sekretów.
if [ "$DEPLOY_COUNT" -gt 0 ]; then
  INTEGRITY_VIOLATIONS=0
  for f in $DEPLOY_FOUND; do
    if [ -f "./$f" ]; then
      if grep -qE "$FORBIDDEN_PATTERNS" "$f" 2>/dev/null; then
        INTEGRITY_VIOLATIONS=$((INTEGRITY_VIOLATIONS+1))
      fi
    fi
  done
  if [ "$INTEGRITY_VIOLATIONS" -eq 0 ]; then
    pass "D-005 Deployment integrity" BLOCKING "Brak hardcoded środowisk, :latest, ani sekretów w deploy."
  else
    fail "D-005 Deployment integrity" BLOCKING "DEPLOYMENT_STATE=INVALID — $INTEGRITY_VIOLATIONS plik(ów) deploy z hardcoded środowiskami / :latest / sekretami."
  fi
fi

# ── D-006 Post-deployment verification ──────────────────────
# Po deployment musi istnieć możliwość udowodnienia:
#   EXPECTED VERSION == ACTUAL RUNNING VERSION
#   SERVICE HEALTHY / READINESS OK / EXPECTED CONFIGURATION / DEPENDENCIES HEALTHY
# Deployment success ≠ process started. Samo słowo "verify" NIE wystarcza —
# musi istnieć dowód porównania oczekiwanej wersji z faktycznie działającą.
if [ "$DEPLOY_COUNT" -gt 0 ]; then
  VERIFY_OK=0
  # Szukamy dowodu weryfikacji WERSJI (expected == actual running version).
  for f in $DEPLOY_FOUND $CONTROL_PLANE_FILES; do
    if [ -f "./$f" ]; then
      if grep -qiE 'expected.*version|actual.*version|running.*version|version.*==|verify.*version|version.*verify' "./$f" 2>/dev/null; then
        VERIFY_OK=1
        break
      fi
    fi
  done
  if [ "$VERIFY_OK" -eq 1 ]; then
    pass "D-006 Post-deployment verification" BLOCKING "Istnieje ścieżka weryfikacji post-deploy (EXPECTED VERSION == ACTUAL RUNNING VERSION)."
  else
    fail "D-006 Post-deployment verification" BLOCKING "DEPLOYMENT_STATE=PARTIAL_CONTROL_PLANE — brak dowodu weryfikacji post-deploy (EXPECTED VERSION == ACTUAL RUNNING VERSION). DEPLOYMENT SUCCESS ≠ DEPLOYMENT VERIFIED."
  fi
fi

# ── D-007 Artifact verification ─────────────────────────────
# Musi istnieć możliwość ustalenia CO wdrażamy: artifact exists, identity,
# version, digest/hash, source, provenance, integrity. "deploy latest" /
# "deploy whatever happens to be there" bez możliwości ustalenia
# WHAT WAS DEPLOYED → FAIL.
if [ "$DEPLOY_COUNT" -gt 0 ]; then
  ARTIFACT_OK=0
  # Szukamy dowodu weryfikacji artefaktu (digest/hash/version/source).
  for f in $DEPLOY_FOUND $CONTROL_PLANE_FILES; do
    if [ -f "./$f" ]; then
      if grep -qiE 'digest|sha256|hash|image.*version|artifact.*version|provenance' "./$f" 2>/dev/null; then
        ARTIFACT_OK=1
        break
      fi
    fi
  done
  # Sprawdź też manifesty/definicje wdrożeniowe (immutable image digests).
  if [ "$ARTIFACT_OK" -eq 0 ]; then
    for m in $DEPLOY_MANIFESTS; do
      if [ -d "./$m" ]; then
        if grep -rqiE 'digest|sha256|hash|image.*version|artifact.*version|provenance' "./$m" 2>/dev/null; then
          ARTIFACT_OK=1
          break
        fi
      fi
    done
  fi
  if [ "$ARTIFACT_OK" -eq 1 ]; then
    pass "D-007 Artifact verification" BLOCKING "Istnieje dowód weryfikacji artefaktu (digest/hash/version/source)."
  else
    fail "D-007 Artifact verification" BLOCKING "DEPLOYMENT_STATE=PARTIAL_CONTROL_PLANE — brak dowodu weryfikacji artefaktu (digest/hash/version/source). ARTIFACT EXISTS ≠ ARTIFACT VERIFIED."
  fi
fi

# ── D-008 Authorization / policy ────────────────────────────
# Deployment jest operacją mutującą infrastrukturę. Musi istnieć:
#   REQUEST → IDENTITY → AUTHORIZATION → POLICY → EXECUTION
# who can deploy / what / where / under which conditions / is approval
# required / is deployment auditable. Brak mechanizmu → FAIL jeśli repo
# deklaruje deployment jako capability.
if [ "$DEPLOY_COUNT" -gt 0 ]; then
  AUTH_OK=0
  # Szukamy dowodu autoryzacji/policy (approval, policy, authorization, role).
  for f in $DEPLOY_FOUND $CONTROL_PLANE_FILES; do
    if [ -f "./$f" ]; then
      if grep -qiE 'approval|authorization|policy|role|permission|audit' "./$f" 2>/dev/null; then
        AUTH_OK=1
        break
      fi
    fi
  done
  if [ "$AUTH_OK" -eq 1 ]; then
    pass "D-008 Authorization / policy" BLOCKING "Istnieje mechanizm autoryzacji/policy dla deploymentu (approval/authorization/policy/role)."
  else
    fail "D-008 Authorization / policy" BLOCKING "DEPLOYMENT_STATE=PARTIAL_CONTROL_PLANE — brak mechanizmu autoryzacji/policy dla deploymentu (who/what/where/conditions/approval)."
  fi
fi

# ── Evidence ─────────────────────────────────────────────────
if verify_blocked; then
  evidence_record "verify:deployment:FAIL" "verify" "deployment/deployment.sh"
else
  evidence_record "verify:deployment:PASS" "verify" "deployment/deployment.sh"
fi

verify_module_exit

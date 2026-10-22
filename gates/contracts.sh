#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# contracts/contracts.sh — Universal Project Template — Repository Certification Engine
# Moduł: CONTRACTS — CONTRACT GATE
# Weryfikuje kontrakty API/platformy: definicja, wersjonowanie (semver),
# schematy walidacji, spójność z implementacją, testy kontraktowe oraz
# wykrywanie breaking changes.
#
# Zasada fail-closed: kontrakt musi być zdefiniowany. Brak kontraktu
# (OpenAPI/Spectral/contracts/*.yaml) = brak umowy = FAIL (BLOCKING).
#
# Checki:
#   CONTRACT-001  Kontrakty API są zdefiniowane (OpenAPI/Spectral)
#   CONTRACT-002  Kontrakty są wersjonowane (semver)
#   CONTRACT-003  Kontrakty mają schematy walidacji (request/response)
#   CONTRACT-004  Kontrakty są spójne z implementacją (best-effort, WARNING)
#   CONTRACT-005  Kontrakty mają testy kontraktowe
#   CONTRACT-006  Breaking changes są wykrywane (diff kontraktów)
# ─────────────────────────────────────────────────────────────
set -u

# shellcheck source=../core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== CONTRACTS — CONTRACT GATE ==="

# ── Lokalizacje kontraktów ──────────────────────────────────
# Kontrakt API może być w kilku miejscach:
#   api/openapi.yaml            — OpenAPI spec
#   contracts/*.yaml            — kontrakty YAML (Spectral)
#   contracts/<domena>/contract.md — kontrakty markdown per domena
#   openapi.yaml                — w root
CONTRACT_FILES=""
for c in api/openapi.yaml openapi.yaml contracts/openapi.yaml; do
  [ -f "$c" ] && CONTRACT_FILES="$CONTRACT_FILES $c"
done
# Kontrakty YAML w contracts/ (Spectral).
while IFS= read -r f; do
  [ -n "$f" ] && CONTRACT_FILES="$CONTRACT_FILES $f"
done < <(find contracts -name '*.yaml' -o -name '*.yml' 2>/dev/null)
# Kontrakty markdown per domena (contract.md).
while IFS= read -r f; do
  [ -n "$f" ] && CONTRACT_FILES="$CONTRACT_FILES $f"
done < <(find contracts -name 'contract.md' 2>/dev/null)

# ── CONTRACT-001: Kontrakty API są zdefiniowane ─────────────
# Fail-closed: brak kontraktu = brak umowy = FAIL.
if [ -n "$CONTRACT_FILES" ]; then
  pass "CONTRACT-001 Kontrakty API są zdefiniowane" BLOCKING "Znaleziono kontrakty:$CONTRACT_FILES"
else
  fail "CONTRACT-001 Kontrakty API są zdefiniowane" BLOCKING "Brak kontraktów (api/openapi.yaml, contracts/*.yaml, contracts/*/contract.md)."
fi

# ── CONTRACT-002: Kontrakty są wersjonowane (semver) ────────
# Każdy kontrakt musi mieć wersję semver (X.Y.Z). Szukamy w nagłówku
# kontraktu (version:, "Version:", "vX.Y.Z", "semver").
SEMVER_OK=0; SEMVER_TOTAL=0
for f in $CONTRACT_FILES; do
  SEMVER_TOTAL=$((SEMVER_TOTAL+1))
  if grep -qiE 'version:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+|v[0-9]+\.[0-9]+\.[0-9]+|semver' "$f" 2>/dev/null; then
    SEMVER_OK=$((SEMVER_OK+1))
  fi
done
if [ "$SEMVER_TOTAL" -gt 0 ]; then
  if [ "$SEMVER_OK" -eq "$SEMVER_TOTAL" ]; then
    pass "CONTRACT-002 Kontrakty są wersjonowane (semver)" BLOCKING "$SEMVER_OK/$SEMVER_TOTAL kontraktów ma wersję semver."
  else
    fail "CONTRACT-002 Kontrakty są wersjonowane (semver)" BLOCKING "Tylko $SEMVER_OK/$SEMVER_TOTAL kontraktów ma wersję semver."
  fi
else
  fail "CONTRACT-002 Kontrakty są wersjonowane (semver)" BLOCKING "Brak kontraktów do wersjonowania (CONTRACT-001 FAIL)."
fi

# ── CONTRACT-003: Kontrakty mają schematy walidacji ─────────
# Każdy endpoint/operacja musi mieć zdefiniowany request/response schema.
# W OpenAPI: sekcje requestBody / responses / schema. W markdown:
# sekcje "Request" / "Response" / "Schema".
SCHEMA_OK=0; SCHEMA_TOTAL=0
for f in $CONTRACT_FILES; do
  SCHEMA_TOTAL=$((SCHEMA_TOTAL+1))
  if grep -qiE 'requestBody|responses:|schema:|## .*Request|## .*Response|## .*Schema' "$f" 2>/dev/null; then
    SCHEMA_OK=$((SCHEMA_OK+1))
  fi
done
if [ "$SCHEMA_TOTAL" -gt 0 ]; then
  if [ "$SCHEMA_OK" -eq "$SCHEMA_TOTAL" ]; then
    pass "CONTRACT-003 Kontrakty mają schematy walidacji" BLOCKING "$SCHEMA_OK/$SCHEMA_TOTAL kontraktów ma schematy request/response."
  else
    fail "CONTRACT-003 Kontrakty mają schematy walidacji" BLOCKING "Tylko $SCHEMA_OK/$SCHEMA_TOTAL kontraktów ma schematy request/response."
  fi
else
  fail "CONTRACT-003 Kontrakty mają schematy walidacji" BLOCKING "Brak kontraktów do sprawdzenia schematów (CONTRACT-001 FAIL)."
fi

# ── CONTRACT-004: Kontrakty są spójne z implementacją ───────
# Best-effort (WARNING): endpointy zadeklarowane w kontrakcie, których nie ma
# w kodzie. Szukamy ścieżek/endpointów w kontrakcie (np. "/health", "/api/...")
# i sprawdzamy czy występują w kodzie (src/, apps/, tools/).
# To jest WARNING — nie blokuje, ale sygnalizuje rozjazd kontrakt↔kod.
if [ -n "$CONTRACT_FILES" ]; then
  MISSING_ENDPOINTS=""
  # Wyciągnij ścieżki endpointów z kontraktów (OpenAPI paths / markdown).
  # Filtrujemy fałszywe pozytywy (application/json, application/xml itd.).
  ENDPOINTS=$(grep -hoE '"/[a-zA-Z0-9_/{}.-]+"|`/[a-zA-Z0-9_/{}.-]+`|/[a-zA-Z0-9_/{}.-]+' $CONTRACT_FILES 2>/dev/null \
    | tr -d '"`' | sort -u | grep -E '^/' \
    | grep -vE '^/application/' | head -50)
  if [ -n "$ENDPOINTS" ]; then
    while IFS= read -r ep; do
      [ -z "$ep" ] && continue
      # Normalizuj: usuń parametry ścieżki {id} → * dla grep.
      ep_grep=$(printf '%s' "$ep" | sed 's/{[^}]*}/\*/g')
      # Szukaj w kodzie (src, apps, tools, system) — best-effort.
      if ! grep -rqF "$ep_grep" src apps tools system 2>/dev/null; then
        MISSING_ENDPOINTS="$MISSING_ENDPOINTS $ep"
      fi
    done <<< "$ENDPOINTS"
  fi
  if [ -z "$MISSING_ENDPOINTS" ]; then
    pass "CONTRACT-004 Kontrakty są spójne z implementacją" WARNING "Wszystkie endpointy z kontraktu obecne w kodzie (best-effort)."
  else
    warn "CONTRACT-004 Kontrakty są spójne z implementacją" "Endpointy z kontraktu nieobecne w kodzie:$MISSING_ENDPOINTS (best-effort)."
  fi
else
  fail "CONTRACT-004 Kontrakty są spójne z implementacją" WARNING "Brak kontraktów do porównania z implementacją (CONTRACT-001 FAIL)."
fi

# ── CONTRACT-005: Kontrakty mają testy kontraktowe ──────────
# Testy kontraktowe w katalogach: tests/contract/, contract-tests/,
# contracts/tests/, tools/verify/tests/test-contracts.sh.
CONTRACT_TEST_DIRS=""
for d in tests/contract contract-tests contracts/tests tests/contracts; do
  [ -d "$d" ] && CONTRACT_TEST_DIRS="$CONTRACT_TEST_DIRS $d"
done
# Test kontraktowy modułu verify.
[ -f "tools/verify/tests/test-contracts.sh" ] && CONTRACT_TEST_DIRS="$CONTRACT_TEST_DIRS tools/verify/tests/test-contracts.sh"

if [ -n "$CONTRACT_TEST_DIRS" ]; then
  pass "CONTRACT-005 Kontrakty mają testy kontraktowe" BLOCKING "Znaleziono testy kontraktowe:$CONTRACT_TEST_DIRS"
else
  fail "CONTRACT-005 Kontrakty mają testy kontraktowe" BLOCKING "Brak testów kontraktowych (tests/contract/, contract-tests/, test-contracts.sh)."
fi

# ── CONTRACT-006: Breaking changes są wykrywane ─────────────
# Mechanizm diff kontraktów: skrypt lub konfiguracja porównująca wersje
# kontraktów (np. tools/verify/contracts/diff.sh, spectral diff, openapi-diff).
DIFF_MECHANISM=""
for d in tools/verify/contracts/diff.sh tools/contracts/diff.sh scripts/contract-diff.sh; do
  [ -f "$d" ] && DIFF_MECHANISM="$DIFF_MECHANISM $d"
done
# Konfiguracja diff (spectral rules / openapi-diff config).
for c in .spectral.yaml .spectral.yml spectral.yaml openapi-diff.yaml; do
  [ -f "$c" ] && DIFF_MECHANISM="$DIFF_MECHANISM $c"
done

if [ -n "$DIFF_MECHANISM" ]; then
  pass "CONTRACT-006 Breaking changes są wykrywane" BLOCKING "Mechanizm diff kontraktów:$DIFF_MECHANISM"
else
  fail "CONTRACT-006 Breaking changes są wykrywane" BLOCKING "Brak mechanizmu diff kontraktów (skrypt lub konfiguracja)."
fi

verify_module_exit

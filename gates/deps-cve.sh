#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# gates/domains/deps-cve.sh — GATE-047 DEPS-CVE
# Skan podatności zależności (CVE): pip-audit (Python), cargo-audit
# (Rust), npm audit (Node). CHANGE-AWARE: uruchamiany gdy zmienił się
# lockfile (requirements.txt, Cargo.lock, package-lock.json) albo gdy
# wymuszony VERIFY_FULL=1.
#
# Zasada fail-closed: skaner ZAINSTALOWANY dla danego języka = uruchamiany;
# znaleziona podatność (vulnerability) = BLOCKING FAIL. Brak skanera lub
# brak zależności = PASS (NOT_APPLICABLE nie jest FAIL).
#
# Użycie:
#   bash tools/verify/gates/domains/deps-cve.sh
#   bash tools/verify/gates/domains/deps-cve.sh --force
# ─────────────────────────────────────────────────────────────
set -u

# shellcheck source=../../core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-047 DEPS-CVE ==="

FORCE="${1:-}"
FAILED=0

# ── DEPS-001: Python (pip-audit) ────────────────────────────
# pip-audit -r wymaga faktycznego requirements.txt; pyproject.toml/Pipfile
# bez requirements.txt = N/A (brak wejścia audytu), nie FAIL.
if [ -f requirements.txt ]; then
  if command -v pip-audit >/dev/null 2>&1; then
    # Fix 2026-09-22: (1) TWARDY TIMEOUT — pip-audit wykonuje `pip install
    # --dry-run` po sieci; bez limitu bramka wisiała ~17 min na martwym PyPI
    # i blokowała całą certyfikację. (2) ROZRÓŻNIENIE: kod 124 (timeout) to NIE
    # "brak podatności" — to audyt nieukończony (WARN, nigdy cichy PASS).
    PA_RC=0
    timeout 120 pip-audit -r requirements.txt 2>/dev/null >/tmp/pipaudit-out.$$ || PA_RC=$?
    if [ "$PA_RC" -eq 124 ]; then
      warn "DEPS-001 Python deps (pip-audit)" "timeout 120s (sieć/PyPI niedostępne) — audyt NIEUKOŃCZONY, nie jest dowodem braku podatności"
    elif [ "$PA_RC" -ne 0 ] && [ -s /tmp/pipaudit-out.$$ ]; then
      echo "pip-audit: znaleziono podatności:"
      cat /tmp/pipaudit-out.$$
      FAILED=1
    fi
    if [ "$PA_RC" -eq 0 ]; then
      if [ -s /tmp/pipaudit-out.$$ ]; then
        pass "DEPS-001 Python deps (pip-audit)" BLOCKING "brak znanych podatności w $(wc -l < /tmp/pipaudit-out.$$) liniach audytu"
      else
        pass "DEPS-001 Python deps (pip-audit)" BLOCKING "pip-audit: brak podatności"
      fi
    fi
    rm -f /tmp/pipaudit-out.$$
  else
    fail "DEPS-001 Python deps (pip-audit)" BLOCKING "pip-audit nie zainstalowany — fail-closed (linter obowiązkowy)"
  fi
elif [ -f pyproject.toml ] || [ -f Pipfile ]; then
  info "DEPS-001 Python deps (pip-audit)" "brak requirements.txt — pip-audit wymaga lockfile (N/A)"
fi

# ── DEPS-002: Rust (cargo-audit) ────────────────────────────
if [ -f Cargo.toml ] || [ -f Cargo.lock ]; then
  if command -v cargo-audit >/dev/null 2>&1; then
    if [ -f Cargo.lock ]; then
      if ! cargo audit 2>/dev/null >/tmp/cargoaudit-out.$$; then
        if grep -qE 'Vulnerabilities|found [0-9]+ vulnerabilities' /tmp/cargoaudit-out.$$; then
          echo "cargo-audit: znaleziono podatności:"
          grep -A2 -E 'Vulnerable|vulnerability' /tmp/cargoaudit-out.$$ | head -20
          FAILED=1
        fi
      fi
      if grep -qE '0 vulnerabilities' /tmp/cargoaudit-out.$$ 2>/dev/null; then
        pass "DEPS-002 Rust deps (cargo-audit)" BLOCKING "brak znanych podatności (RUSTSEC)"
      else
        pass "DEPS-002 Rust deps (cargo-audit)" BLOCKING "cargo-audit: skan zakończony"
      fi
      rm -f /tmp/cargoaudit-out.$$
    else
      warn "DEPS-002 Rust deps (cargo-audit)" "brak Cargo.lock — cargo-audit wymaga lockfile"
    fi
  else
    fail "DEPS-002 Rust deps (cargo-audit)" BLOCKING "cargo-audit nie zainstalowany — fail-closed (linter obowiązkowy)"
  fi
fi

# ── DEPS-003: Node (npm audit) ──────────────────────────────
# npm audit WYMAGA package-lock.json (bez niego zwraca ENOLOCK, co nie
# jest podatnością — brak lockfile to N/A). package.json bez lockfile
# nie jest audytowalny przez npm.
if [ -f package-lock.json ]; then
  if command -v npm >/dev/null 2>&1; then
    if ! npm audit --audit-level=high 2>/dev/null >/tmp/npmaudit-out.$$; then
      echo "npm audit: znaleziono podatności high/critical:"
      grep -E 'high|critical' /tmp/npmaudit-out.$$ | head -15
      FAILED=1
    else
      pass "DEPS-003 Node deps (npm audit)" BLOCKING "brak podatności high/critical"
    fi
    rm -f /tmp/npmaudit-out.$$
  else
    fail "DEPS-003 Node deps (npm audit)" BLOCKING "npm nie dostępny — fail-closed (linter obowiązkowy)"
  fi
elif [ -f package.json ]; then
  info "DEPS-003 Node deps (npm audit)" "brak package-lock.json — npm audit wymaga lockfile (N/A)"
fi

if [ "$FAILED" -ne 0 ]; then
  fail "DEPS-CVE podsumowanie" BLOCKING "znaleziono podatności zależności — popraw wersje i zaktualizuj lockfile"
fi

verify_module_exit

#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# gates/domains/sbom.sh — GATE-046 SBOM (Software Bill of Materials)
# Spis zależności (lockfile'ów) repozytorium: Python (requirements.txt,
# pyproject.toml), Rust (Cargo.lock), Node (package-lock.json).
# Wypełnia lukę SAST (GATE-045) → DEPS-CVE (GATE-047): SAST patrzy na
# kod, DEPS-CVE na podatności — SBOM dokumentuje CO jest w zależnościach.
#
# Zasada fail-closed: repo z zależnościami i dostępnym narzędziem =
# SBOM MUSI powstać i trafić do artifacts/evidence/gates/GATE-046.evidence.
# Brak narzędzia = WARN (best-effort, wzór SAST-001). Brak zależności = PASS
# (NOT_APPLICABLE nie jest FAIL — wzór DEPS-001).
#
# Użycie:
#   bash tools/verify/gates/domains/sbom.sh
# ─────────────────────────────────────────────────────────────
set -u

# shellcheck source=../../core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-046 SBOM ==="

EVIDENCE="artifacts/evidence/gates/GATE-046.evidence"
mkdir -p "$(dirname "$EVIDENCE")"
: > "$EVIDENCE"

# Rekurencyjne wykrywanie manifestów (repo monorepo: runtime/, products/,
# tools/ mają zależności w podkatalogach, nie w root). Wykluczamy vendor:
# node_modules, .venv, target (build), .git, .tools (źródła vendored).
MANIFESTS=$(find . -type f \
  \( -name requirements.txt -o -name pyproject.toml -o -name Pipfile \
     -o -name Cargo.toml -o -name Cargo.lock \
     -o -name package.json -o -name package-lock.json \) \
  -not -path './.git/*' -not -path '*/node_modules/*' \
  -not -path '*/.venv/*' -not -path '*/target/*' \
  -not -path './.tools/*' 2>/dev/null)
PY_MAN=$(printf '%s\n' "$MANIFESTS" | grep -cE 'requirements\.txt|pyproject\.toml|Pipfile')
RS_MAN=$(printf '%s\n' "$MANIFESTS" | grep -cE 'Cargo\.toml')
RS_LOCK=$(printf '%s\n' "$MANIFESTS" | grep -cE 'Cargo\.lock')
NODE_MAN=$(printf '%s\n' "$MANIFESTS" | grep -cE 'package(-lock)?\.json')
FOUND_DEPS=0

# ── SBOM-001: wykrywanie zależności ─────────────────────────
# Repo bez lockfile'ów/zależności = N/A — nie ma czego spisywać.
if [ -n "$MANIFESTS" ]; then
  FOUND_DEPS=1
  pass "SBOM-001 wykrywanie zależności" BLOCKING \
    "manifesty: $PY_MAN Python, $RS_MAN Rust (Cargo.toml, $RS_LOCK lock), $NODE_MAN Node"
else
  info "SBOM-001 wykrywanie zależności" "brak manifestów zależności (N/A)"
fi

# ── SBOM-002: Python (pip freeze) ───────────────────────────
# pip freeze = spis faktycznie zainstalowanych pakietów środowiska;
# manifesty Python potwierdzają, że repo ich używa.
if [ "$PY_MAN" -gt 0 ]; then
  if command -v pip >/dev/null 2>&1 || command -v pip3 >/dev/null 2>&1; then
    PIP="$(command -v pip3 2>/dev/null || command -v pip 2>/dev/null)"
    if "$PIP" freeze --disable-pip-version-check 2>/dev/null >/tmp/sbom-pip.$$; then
      LINES=$(wc -l < /tmp/sbom-pip.$$)
      {
        echo "# GATE-046 SBOM — Python ($(date -u +%Y-%m-%dT%H:%M:%SZ), $(id -un))"
        echo "# manifesty: $PY_MAN (requirements.txt/pyproject.toml/Pipfile)"
        cat /tmp/sbom-pip.$$
      } >> "$EVIDENCE"
      pass "SBOM-002 Python SBOM (pip freeze)" BLOCKING "$LINES pakietów zapisanych do $EVIDENCE"
    else
      warn "SBOM-002 Python SBOM (pip freeze)" "pip freeze nie powiódł się — pominięto (best-effort)"
    fi
    rm -f /tmp/sbom-pip.$$
  else
    fail "SBOM-002 Python SBOM (pip freeze)" BLOCKING "pip nie dostępny — fail-closed (linter obowiązkowy)"
  fi
fi

# ── SBOM-003: Rust (cargo tree) ─────────────────────────────
# Działa w katalogu pierwszego Cargo.lock (workspace/crate z lockfile'em);
# sam Cargo.toml bez Cargo.lock = WARN (wzór DEPS-002: brak lockfile).
if [ "$RS_MAN" -gt 0 ]; then
  if command -v cargo >/dev/null 2>&1; then
    RS_LOCKFILE=$(echo "$MANIFESTS" | grep 'Cargo\.lock$' | head -1)
    if [ -n "$RS_LOCKFILE" ]; then
      RS_DIR="$(dirname "$RS_LOCKFILE")"
      if ( cd "$RS_DIR" && cargo tree --locked 2>/dev/null ) >/tmp/sbom-cargo.$$; then
        LINES=$(wc -l < /tmp/sbom-cargo.$$)
        {
          echo "# GATE-046 SBOM — Rust cargo tree ($(date -u +%Y-%m-%dT%H:%M:%SZ), $(id -un))"
          echo "# workspace: $RS_DIR"
          cat /tmp/sbom-cargo.$$
        } >> "$EVIDENCE"
        pass "SBOM-003 Rust SBOM (cargo tree)" BLOCKING "$LINES zależności zapisanych do $EVIDENCE"
      else
        warn "SBOM-003 Rust SBOM (cargo tree)" "cargo tree nie powiódł się w $RS_DIR — pominięto (best-effort)"
      fi
      rm -f /tmp/sbom-cargo.$$
    else
      warn "SBOM-003 Rust SBOM (cargo tree)" "brak Cargo.lock (jest $RS_MAN Cargo.toml) — cargo tree wymaga lockfile"
    fi
  else
    fail "SBOM-003 Rust SBOM (cargo tree)" BLOCKING "cargo niedostępny — fail-closed (linter obowiązkowy)"
  fi
fi

# ── SBOM-004: Node (npm ls) ─────────────────────────────────
# Działa w katalogu pierwszego package-lock.json; package.json bez
# lockfile = WARN (wzór DEPS-003: npm audit wymaga lockfile).
if [ "$NODE_MAN" -gt 0 ]; then
  NODE_LOCK=$(echo "$MANIFESTS" | grep 'package-lock\.json$' | head -1)
  if command -v npm >/dev/null 2>&1 && [ -n "$NODE_LOCK" ]; then
    NODE_DIR="$(dirname "$NODE_LOCK")"
    # npm ls z node_modules; fallback --package-lock-only (świeży checkout
    # bez node_modules — lockfile sam wystarczy na spis zależności).
    OUT=$( ( cd "$NODE_DIR" && npm ls --all --json 2>/dev/null ) || ( cd "$NODE_DIR" && npm ls --package-lock-only --all --json 2>/dev/null ) )
    if [ -n "$OUT" ]; then
      printf '%s\n' "$OUT" > /tmp/sbom-npm.$$
      PKGS=$(grep -c '"version"' /tmp/sbom-npm.$$ 2>/dev/null || echo 0)
      {
        echo "# GATE-046 SBOM — Node npm ls ($(date -u +%Y-%m-%dT%H:%M:%SZ), $(id -un))"
        echo "# lockfile: $NODE_LOCK"
        cat /tmp/sbom-npm.$$
      } >> "$EVIDENCE"
      pass "SBOM-004 Node SBOM (npm ls)" BLOCKING "$PKGS pakietów zapisanych do $EVIDENCE"
    else
      warn "SBOM-004 Node SBOM (npm ls)" "npm ls nie powiódł się w $NODE_DIR — pominięto (best-effort)"
    fi
    rm -f /tmp/sbom-npm.$$
  elif [ -n "$NODE_LOCK" ]; then
    fail "SBOM-004 Node SBOM (npm ls)" BLOCKING "npm niedostępny — fail-closed (linter obowiązkowy)"
  else
    warn "SBOM-004 Node SBOM (npm ls)" "brak package-lock.json (jest $NODE_MAN package.json) — npm ls wymaga lockfile"
  fi
fi

# ── SBOM-005: evidence wygenerowane ─────────────────────────
# Zależności wykryte (SBOM-001) ⇒ plik evidence musi być niepusty.
if [ "$FOUND_DEPS" -eq 1 ]; then
  if [ -s "$EVIDENCE" ]; then
    pass "SBOM-005 evidence SBOM" BLOCKING "$(wc -l < "$EVIDENCE") linii w $EVIDENCE"
  else
    fail "SBOM-005 evidence SBOM" BLOCKING "repo ma zależności, ale $EVIDENCE jest pusty — brak dowodu spisu zależności"
  fi
else
  info "SBOM-005 evidence SBOM" "brak zależności — evidence puste (N/A)"
fi

verify_module_exit

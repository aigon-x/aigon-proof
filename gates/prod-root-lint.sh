#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/prod-root-lint.sh — gate prod-root-lint (cyclic:6h)
#
#  STERILE ROOT ENFORCEMENT (skill prod-filesystem-canon §26-28).
#  Sprawdza root /opt/PROD przeciw ROOT MANIFEST
#  (config/prod-root-manifest.yaml):
#    - allowed_dirs / allowed_hidden / allowed_files → PASS
#    - known_legacy / protected_secrets / known_transient → WARN
#      (sklasyfikowane — wymagają decyzji, nie blokują)
#    - forbidden_patterns → FAIL (wzorzec zakazany w root)
#    - cokolwiek innego → FAIL (requires classification)
#
#  Kontrakt hook-runnera (tools/gates/*.sh):
#    exit 0 = PASS, 1 = FAIL, 2 = WARN;
#    ostatnia linia stdout = komunikat.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST="${AIGON_ROOT_MANIFEST:-$ROOT/config/prod-root-manifest.yaml}"

failures=0
warnings=0
found_fail=""
found_warn=""

[ -f "$MANIFEST" ] || { echo "WARN: brak manifestu $MANIFEST — nie można sprawdzić root"; exit 2; }

# ── Parsowanie manifestu (python3 — tak jak hook-runner.sh) ───────────
# Zwraca linie listy z sekcji <key> (puste gdy brak sekcji).
section() {
  python3 - "$MANIFEST" "$1" << 'PYEOF'
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
items = d.get(sys.argv[2]) if isinstance(d, dict) else None
if isinstance(items, list):
    print("\n".join(str(i) for i in items))
PYEOF
}

# Wzorce zakazane: shell glob na nazwie wpisu (basename).
# Wpis jawnie wymieniony w allowed_*/known_*/protected_* MA PIERWSZEŃSTWO.
forbidden_glob() {
  local name="$1" pats pat
  pats="$(section forbidden_patterns)"
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    case "$name" in
      $pat) return 0 ;;
    esac
  done <<< "$pats"
  return 1
}

# ── Zbiory z manifestu ────────────────────────────────────────────────
ALLOWED="$( { section allowed_dirs; section allowed_hidden; section allowed_files; } | sort -u )"
KNOWN="$(  { section known_legacy; section protected_secrets; section known_transient; } | sort -u )"

# ── Inwentaryzacja root ───────────────────────────────────────────────
mapfile -t ENTRIES < <(ls -A "$ROOT" 2>/dev/null)

for name in "${ENTRIES[@]:-}"; do
  [ -n "$name" ] || continue

  # 1. jawnie dozwolone
  if grep -qxF "$name" <<< "$ALLOWED"; then
    continue
  fi

  # 2. sklasyfikowane (legacy/sekrety/transient) — WARN
  if grep -qxF "$name" <<< "$KNOWN"; then
    warnings=$((warnings + 1))
    found_warn="${found_warn}  WARN $name (sklasyfikowany w manifeście — oczekuje decyzji)"$'\n'
    continue
  fi

  # 3. wzorzec zakazany — FAIL
  if forbidden_glob "$name"; then
    failures=$((failures + 1))
    found_fail="${found_fail}  FAIL $name (wzorzec zakazany w root)"$'\n'
    continue
  fi

  # 4. nieznany wpis — FAIL (requires classification)
  failures=$((failures + 1))
  found_fail="${found_fail}  FAIL $name (nieautoryzowany wpis root — requires classification)"$'\n'
done

# ── Werdykt (kontrakt hook-runnera: ostatnia linia = komunikat) ───────
if [ "$failures" -gt 0 ]; then
  if [ "$warnings" -gt 0 ]; then
    echo "WARN: pozycje sklasyfikowane (oczekują decyzji):"
    echo -n "$found_warn" | sed 's/^/  /'
  fi
  echo -n "$found_fail" | sed 's/^/  /'
  echo "FAIL: prod-root-lint — ${failures} nieautoryzowanych wpisów w root /opt/PROD (wymagana klasyfikacja)"
  exit 1
fi
if [ "$warnings" -gt 0 ]; then
  echo "PASS: root zgodny z manifestem (${warnings} pozycji sklasyfikowanych do decyzji):"
  echo -n "$found_warn" | sed 's/^/  /'
  exit 0
fi
echo "PASS: root /opt/PROD sterylny — wszystkie wpisy zgodne z manifestem"
exit 0

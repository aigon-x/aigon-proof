#!/usr/bin/env bash
# prompt-budget — budżet tokenów promptu i skilli (LAW-NAP-1, LAW-METRIC-INDEPENDENCE).
# FAIL = przekroczony budżet. Progi w bajtach (tokeny ≈ B/4), żeby nie zgadywać.
#   core (AGENTS.md / prompt-core.md): 4096 B  (~1k tok)
#   SKILL.md:                          8192 B  (~2k tok)
#   indeks pamięci (MEMORY.md):         200 linii
# Użycie: prompt-budget.sh [--selftest|--json]
set -uo pipefail
ROOT="${PROMPT_BUDGET_ROOT:-/opt/PROD}"
CORE_LIMIT=4096
SKILL_LIMIT=8192
MEM_LIMIT=200
fail=0

check_core() {
  for f in "$ROOT/AGENTS.md" "$ROOT/config/canonical/prompt-core.md"; do
    [ -f "$f" ] || { echo "MISSING $f"; fail=1; continue; }
    local b; b=$(wc -c <"$f")
    if [ "$b" -gt "$CORE_LIMIT" ]; then
      echo "FAIL core $(basename "$f") ${b}B > ${CORE_LIMIT}B (~$((b/4)) tok)"
      fail=1
    else
      echo "OK   core $(basename "$f") ${b}B (~$((b/4)) tok)"
    fi
  done
}

check_skills() {
  local over=0 total=0 max=0 worst=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    local b; b=$(wc -c <"$f"); total=$((total+1))
    if [ "$b" -gt "$max" ]; then max=$b; worst=$f; fi
    if [ "$b" -gt "$SKILL_LIMIT" ]; then over=$((over+1)); fi
  done < <(find "$ROOT/skills" -name SKILL.md -type f 2>/dev/null)
  echo "skills: $total plików, ponad budżet: $over, największy: $((max/4)) tok ($worst)"
  [ "$over" -eq 0 ] || fail=1
}

check_memory() {
  local n=0
  for f in "$HOME/.qwen/MEMORY.md" "$HOME/.qwen/projects/-opt-PROD/memory/MEMORY.md"; do
    [ -f "$f" ] || continue
    local c; c=$(wc -l <"$f"); n=$((n+c))
    if [ "$c" -gt "$MEM_LIMIT" ]; then echo "FAIL memory $f ${c} linii > ${MEM_LIMIT}"; fail=1; fi
  done
  echo "memory index: ${n} linii (limit ${MEM_LIMIT}/plik)"
}

selftest() {
  local tmp; tmp=$(mktemp -d); local rc=0
  mkdir -p "$tmp/skills/x" "$tmp/config/canonical"
  printf 'krotki rdzen\n' >"$tmp/AGENTS.md"
  cp "$tmp/AGENTS.md" "$tmp/config/canonical/prompt-core.md"
  printf 'skill ok\n' >"$tmp/skills/x/SKILL.md"
  PROMPT_BUDGET_ROOT="$tmp" bash "$0" >/dev/null 2>&1 || { echo "selftest NEG1: PASS-case failed"; rc=1; }
  python3 - "$tmp/skills/x/SKILL.md" <<'PY'
import sys; open(sys.argv[1],'w').write('x'*9000)
PY
  if PROMPT_BUDGET_ROOT="$tmp" bash "$0" >/dev/null 2>&1; then
    echo "selftest NEG2: FAIL-case did NOT fail"; rc=1
  fi
  rm -rf "$tmp"
  [ "$rc" -eq 0 ] && echo "selftest: 2/2 PASS" || echo "selftest: FAIL"
  return $rc
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  --json) check_core >/dev/null; echo "{\"fail\":$fail,\"core_limit\":$CORE_LIMIT,\"skill_limit\":$SKILL_LIMIT}"; exit $fail ;;
esac
echo "== prompt-budget (root=$ROOT) =="
check_core; check_skills; check_memory
[ "$fail" -eq 0 ] && echo "PASS" || echo "FAIL"
exit $fail

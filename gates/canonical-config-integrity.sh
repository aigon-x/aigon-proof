#!/usr/bin/env bash
# ============================================================================
# canonical-config-integrity.sh — kanoniczny runner warstwy config/canonical
# ============================================================================
# Weryfikuje (fail-closed) warstwę, której NIE obejmuje `tools/test` (kod):
#   [1] składnia YAML każdego pliku config/canonical/*.yaml
#   [2] capabilities.yaml — rejestr capability (komplet pól)
#   [3] constitution-fitness-map.yaml — każde prawo ma cmd, a cmd istnieje
#   [4] gate skrypty tools/gates — bash -n (składnia)
# Exit: 0 = PASS, 1 = FAIL. Read-only — nie modyfikuje plików.
# ============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1
FAIL=0
ok(){ echo "  OK  $1"; }
bad(){ echo "  BAD $1"; FAIL=1; }

echo "== canonical-config-integrity =="

# [1] YAML składnia — wszystkie pliki config/canonical
YAML_BAD=0
while IFS= read -r f; do
  python3 -c "import yaml; yaml.safe_load(open('$f'))" 2>/dev/null || { bad "YAML: $f"; YAML_BAD=1; }
done < <(find config/canonical -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)
[ "$YAML_BAD" -eq 0 ] && ok "składnia YAML config/canonical (wszystkie pliki)"

# [2] capabilities.yaml — rejestr capability (komplet pól)
python3 - <<'PY' 2>/dev/null && ok "capabilities.yaml (komplet pól)" || bad "capabilities.yaml"
import yaml
d = yaml.safe_load(open('config/canonical/capabilities.yaml'))
assert isinstance(d.get('capabilities'), list), "brak listy capabilities"
for c in d['capabilities']:
    for k in ('id','risk','owner','scope','audit','revocable'):
        assert k in c, f"capability {c.get('id')} brak pola '{k}'"
ids = [c['id'] for c in d['capabilities']]
assert len(ids) == len(set(ids)), "duplikat id capability"
print(f"  {len(ids)} capabilities, wszystkie kompletne")
PY

# [3] constitution-fitness-map.yaml — cmd istnieje
python3 - <<'PY' 2>/dev/null && ok "constitution-fitness-map.yaml (cmd istnieje)" || bad "fitness-map"
import yaml, os
d = yaml.safe_load(open('config/canonical/constitution-fitness-map.yaml'))
n = 0
for k, e in d.get('fitness', {}).items():
    if isinstance(e, dict) and 'cmd' in e:
        n += 1
        assert os.path.exists(e['cmd']), f"prawo {k}: cmd '{e['cmd']}' nie istnieje"
print(f"  {n} praw z cmd, wszystkie istnieją")
PY

# [4] gate skrypty — bash -n
for g in tools/gates/*.sh; do
  bash -n "$g" 2>/dev/null || bad "bash -n: $g"
done
ok "bash -n tools/gates/*.sh"

echo ""
[ "$FAIL" -eq 0 ] && { echo "canonical-config-integrity: PASS"; exit 0; }
echo "canonical-config-integrity: FAIL"
exit 1

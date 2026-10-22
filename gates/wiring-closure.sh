#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/wiring-closure.sh — gate wiring-closure (FAST)
#
#  PO CO (rozkaz Suwerena 2026-10-02, masterprompt Runtime Necropsy):
#    po jednorazowym audycie grafu: nowy skill/capability/tool/event/workflow
#    NIE MOŻE wejść do repo jako niezarejestrowany sierota. Zastany dług
#    jest na liście ratchet; wolno go TYLKO zmniejszać.
#
#  CO MIERZY (statycznie, bez runtime):
#    1. capability.extra — top-level C-xxx w capabilities.yaml poza `entries`
#       (loader ManifestSet czyta wyłącznie entries; extra = DEFINED_ONLY)
#    2. crate.orphan — runtime/crates/*/Cargo.toml poza [workspace].members
#    3. workflow.fiction — workflow, którego WSZYSTKIE kroki to echo|noop
#    4. plugin.placeholder — plugin z "not implemented" / "Placeholder" w opisie
#
#  RATCHET: config/canonical/wiring-closure-debt.txt
#    - nowy sierota SPOZA listy -> FAIL
#    - wpis na liście, który JUŻ NIE jest sierotą -> FAIL (dług spłacony)
#
#  KONTRAKT hook-runner: 0=PASS, 1=FAIL, 2=WARN.
#  Env (testy / override):
#    AIGON_WIRING_DEBT, AIGON_CAPS_YAML, AIGON_WORKFLOWS_YAML,
#    AIGON_PLUGINS_YAML, AIGON_CARGO_TOML, AIGON_CRATES_DIR
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEBT="${AIGON_WIRING_DEBT:-$ROOT/config/canonical/wiring-closure-debt.txt}"
CAPS="${AIGON_CAPS_YAML:-$ROOT/runtime/manifests/capabilities.yaml}"
WF="${AIGON_WORKFLOWS_YAML:-$ROOT/runtime/manifests/workflows.yaml}"
PLUG="${AIGON_PLUGINS_YAML:-$ROOT/runtime/manifests/plugins.yaml}"
CARGO="${AIGON_CARGO_TOML:-$ROOT/Cargo.toml}"
CRATES="${AIGON_CRATES_DIR:-$ROOT/runtime/crates}"

if [ ! -f "$DEBT" ]; then
  echo "wiring-closure: FAIL (brak listy długu: $DEBT)"
  exit 1
fi
if [ ! -f "$CAPS" ]; then
  echo "wiring-closure: FAIL (brak capabilities.yaml: $CAPS)"
  exit 1
fi

report="$(python3 - "$DEBT" "$CAPS" "$WF" "$PLUG" "$CARGO" "$CRATES" <<'PY'
import os, re, sys

debt_path, caps_path, wf_path, plug_path, cargo_path, crates_dir = sys.argv[1:7]

try:
    import yaml
except ImportError:
    print("FAIL: brak PyYAML")
    sys.exit(1)

def load_yaml(path):
    if not path or not os.path.isfile(path):
        return {}
    with open(path, encoding="utf-8") as fh:
        return yaml.safe_load(fh) or {}

debt = set()
if os.path.isfile(debt_path):
    for ln in open(debt_path, encoding="utf-8"):
        ln = ln.split("#", 1)[0].strip()
        if ln:
            debt.add(ln)

observed = set()

# 1. extra C-xxx top-level keys
caps = load_yaml(caps_path)
entries = caps.get("entries") or []
entry_names = {str(e.get("name")) for e in entries if isinstance(e, dict) and e.get("name")}
for k in caps:
    ks = str(k)
    if re.fullmatch(r"C-\d{3}", ks) and ks not in entry_names:
        observed.add(f"capability.extra:{ks}")

# 2. crates outside workspace
members = set()
if os.path.isfile(cargo_path):
    text = open(cargo_path, encoding="utf-8").read()
    members = set(re.findall(r'"runtime/crates/([^"]+)"', text))
if os.path.isdir(crates_dir):
    for name in os.listdir(crates_dir):
        crate = os.path.join(crates_dir, name)
        if os.path.isfile(os.path.join(crate, "Cargo.toml")) and name not in members:
            observed.add(f"crate.orphan:{name}")

# 3. fiction workflows (all steps echo|noop)
wf = load_yaml(wf_path)
for e in (wf.get("entries") or []):
    if not isinstance(e, dict):
        continue
    name = e.get("name")
    steps = e.get("steps") or []
    acts = [s.get("action") for s in steps if isinstance(s, dict)]
    if name and acts and all(a in ("noop", "echo") for a in acts):
        observed.add(f"workflow.fiction:{name}")

# 4. placeholder plugins
plug = load_yaml(plug_path)
pat = re.compile(r"not implemented|placeholder", re.I)
for e in (plug.get("entries") or []):
    if not isinstance(e, dict):
        continue
    name = e.get("name")
    desc = str(e.get("description") or "")
    if name and pat.search(desc):
        observed.add(f"plugin.placeholder:{name}")

new_orphans = sorted(observed - debt)
paid = sorted(debt - observed)

print(f"observed={len(observed)} debt={len(debt)} new={len(new_orphans)} paid={len(paid)}")
if new_orphans:
    print("NEW_ORPHANS")
    for x in new_orphans:
        print(f"  {x}")
if paid:
    print("PAID_DEBT_STILL_LISTED")
    for x in paid:
        print(f"  {x}")

if new_orphans or paid:
    sys.exit(1)
sys.exit(0)
PY
)"
rc=$?
echo "$report"
if [ "$rc" -eq 0 ]; then
  echo "wiring-closure: PASS"
  exit 0
fi
echo "wiring-closure: FAIL (nowy sierota albo spłacony dług nadal na liście)"
exit 1

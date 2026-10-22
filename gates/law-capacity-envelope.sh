#!/usr/bin/env bash
# law-capacity-envelope.sh — LAW-CAPACITY-ENVELOPE (S10-T1)
# Każdy węzeł z config/mesh-nodes.yaml (poza expected_down: true) ma kopertę
# pojemności (cores, mem_mb, load1, eligible, slots) w aigon-mesh-capacity.prom,
# a plik jest młodszy niż TTL. Brak węzła = UNKNOWN, stary plik = STALE —
# oba rc=1, nigdy PASS. Read-only.
# Wejścia: CAPACITY_PROM, MESH_NODES, CAPACITY_TTL.
set -uo pipefail
ROOT="${AIGON_ROOT:-/opt/PROD}"
CAPACITY_PROM="${CAPACITY_PROM:-/var/lib/node_exporter/textfile_collector/aigon-mesh-capacity.prom}"
MESH_NODES="${MESH_NODES:-$ROOT/config/mesh-nodes.yaml}"
CAPACITY_TTL="${CAPACITY_TTL:-600}"
export CAPACITY_PROM MESH_NODES CAPACITY_TTL

timeout 30 python3 - <<'PY'
import os, re, sys, time, yaml
p, ttl = os.environ["CAPACITY_PROM"], int(os.environ["CAPACITY_TTL"])
if not os.path.exists(p):
    print(f"[UNKNOWN] brak koperty {p} (EVIDENCE_MISSING)"); print("STATUS: UNKNOWN"); sys.exit(1)
age = int(time.time() - os.path.getmtime(p))
nodes_cfg = (yaml.safe_load(open(os.environ["MESH_NODES"])) or {}).get("nodes") or {}
want = {n for n, c in nodes_cfg.items() if isinstance(c, dict) and not c.get("expected_down")}
skipped = sorted(n for n, c in nodes_cfg.items() if isinstance(c, dict) and c.get("expected_down"))
need = ("cores", "mem_mb", "load1", "eligible", "slots")
have = {}
for line in open(p):
    m = re.match(r'aigon_mesh_capacity_(\w+)\{[^}]*node="([^"]+)"[^}]*\}\s+(\S+)', line)
    if m: have.setdefault(m.group(2), {})[m.group(1)] = m.group(3)
st = "PASS"
if age > ttl:
    st = "STALE"; print(f"[STALE] koperta ma {age}s > TTL {ttl}s (EVIDENCE_STALE)")
else:
    print(f"[PASS] koperta świeża ({age}s <= {ttl}s)")
for n in sorted(want):
    miss = [k for k in need if k not in have.get(n, {})]
    if miss:
        st = "UNKNOWN" if st == "PASS" else st
        print(f"[UNKNOWN] {n}: brak {','.join(miss)}")
    else:
        print(f"[PASS] {n}: cores={have[n]['cores']} load1={have[n]['load1']} eligible={have[n]['eligible']} slots={have[n]['slots']}")
for n in skipped: print(f"[NOT_APPLICABLE] {n}: expected_down (reason_code=DEPENDENCY_DOWN)")
if not want: st = "UNKNOWN"; print("[UNKNOWN] 0 węzłów w mesh-nodes.yaml")
print(f"STATUS: {st}")
sys.exit(0 if st == "PASS" else 1)
PY

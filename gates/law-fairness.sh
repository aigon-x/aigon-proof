#!/usr/bin/env bash
# law-fairness.sh — LAW-FAIRNESS (S10-T2, zależy od S10-T1)
# Test hałaśliwego sąsiada na kopercie pojemności:
#  (a) żaden węzeł z load1/cores >= NOISY_RATIO (2.0) nie jest eligible;
#  (b) przy >= 2 węzłach eligible żaden nie trzyma > MAX_SLOT_SHARE slotów.
# Brak/stara koperta = UNKNOWN (rc=1). Read-only.
# Wejścia: CAPACITY_PROM, CAPACITY_TTL, NOISY_RATIO, MAX_SLOT_SHARE.
set -uo pipefail
CAPACITY_PROM="${CAPACITY_PROM:-/var/lib/node_exporter/textfile_collector/aigon-mesh-capacity.prom}"
export CAPACITY_PROM CAPACITY_TTL="${CAPACITY_TTL:-600}" NOISY_RATIO="${NOISY_RATIO:-2.0}" MAX_SLOT_SHARE="${MAX_SLOT_SHARE:-0.6}"

timeout 30 python3 - <<'PY'
import os, re, sys, time
p = os.environ["CAPACITY_PROM"]
if not os.path.exists(p) or time.time() - os.path.getmtime(p) > int(os.environ["CAPACITY_TTL"]):
    print("[UNKNOWN] brak/nieświeża koperta pojemności (S10-T1)"); print("STATUS: UNKNOWN"); sys.exit(1)
nd = {}
for line in open(p):
    m = re.match(r'aigon_mesh_capacity_(\w+)\{[^}]*node="([^"]+)"[^}]*\}\s+(\S+)', line)
    if m:
        try: nd.setdefault(m.group(2), {})[m.group(1)] = float(m.group(3))
        except ValueError: pass
noisy, share = float(os.environ["NOISY_RATIO"]), float(os.environ["MAX_SLOT_SHARE"])
fail = 0
for n, v in sorted(nd.items()):
    c, l = v.get("cores") or 0, v.get("load1")
    if c and l is not None and l / c >= noisy and v.get("eligible") == 1:
        fail += 1; print(f"[FAIL] {n}: hałaśliwy sąsiad load1/cores={l/c:.2f} >= {noisy} a eligible=1")
elig = {n: v.get("slots", 0) for n, v in nd.items() if v.get("eligible") == 1}
tot = sum(elig.values())
if len(elig) >= 2 and tot > 0:
    top, s = max(elig.items(), key=lambda x: x[1])
    if s / tot > share: fail += 1; print(f"[FAIL] {top} trzyma {s/tot:.0%} slotów (> {share:.0%}) — monopolizacja roju")
    else: print(f"[PASS] rozkład slotów: max {top} {s/tot:.0%} <= {share:.0%} ({len(elig)} eligible)")
else:
    print(f"[INFO] eligible={len(elig)} slotów={tot:g} — test monopolizacji NOT_APPLICABLE")
if not fail: print("[PASS] brak hałaśliwego sąsiada w puli eligible")
print("STATUS: " + ("FAIL" if fail else "PASS"))
sys.exit(1 if fail else 0)
PY

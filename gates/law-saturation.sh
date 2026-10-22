#!/usr/bin/env bash
# law-saturation.sh — LAW-SATURATION (S10-T3, rozszerza LAW-NOFALL-1 / W6)
# Naruszeniem jest DISPATCH na przeciążony węzeł, nie samo przeciążenie:
# load1 >= cores przy eligible=1 albo slots>0 = FAIL. Przeciążony i
# wykluczony = poprawne skipped_overload. Wykonawca W6 (mesh-duty.sh) musi
# eksportować aigon_mesh_duty_condition_ok{condition="w6"} — brak = UNKNOWN.
# Read-only. Wejścia: CAPACITY_PROM, MESH_DUTY_PROM, CAPACITY_TTL.
set -uo pipefail
TC=/var/lib/node_exporter/textfile_collector
export CAPACITY_PROM="${CAPACITY_PROM:-$TC/aigon-mesh-capacity.prom}" MESH_DUTY_PROM="${MESH_DUTY_PROM:-$TC/aigon-mesh-duty.prom}" CAPACITY_TTL="${CAPACITY_TTL:-600}"

timeout 30 python3 - <<'PY'
import os, re, sys, time
p, dp = os.environ["CAPACITY_PROM"], os.environ["MESH_DUTY_PROM"]
unknown = fail = 0
if not os.path.exists(p) or time.time() - os.path.getmtime(p) > int(os.environ["CAPACITY_TTL"]):
    print("[UNKNOWN] brak/nieświeża koperta pojemności"); unknown += 1; nd = {}
else:
    nd = {}
    for line in open(p):
        m = re.match(r'aigon_mesh_capacity_(\w+)\{[^}]*node="([^"]+)"[^}]*\}\s+(\S+)', line)
        if m:
            try: nd.setdefault(m.group(2), {})[m.group(1)] = float(m.group(3))
            except ValueError: pass
over = 0
for n, v in sorted(nd.items()):
    c, l = v.get("cores"), v.get("load1")
    if c is None or l is None: continue
    if l >= c:
        over += 1
        if v.get("eligible") == 1 or (v.get("slots") or 0) > 0:
            fail += 1; print(f"[FAIL] {n}: load1={l:g} >= cores={c:g}, a eligible={v.get('eligible'):g} slots={v.get('slots', 0):g} — dispatch na przeciążony węzeł")
        else:
            print(f"[PASS] {n}: przeciążony (load1={l:g}/{c:g}) i wykluczony — skipped_overload")
w6 = None
if os.path.exists(dp):
    for line in open(dp):
        m = re.match(r'aigon_mesh_duty_condition_ok\{condition="w6"\}\s+(\S+)', line)
        if m: w6 = m.group(1)
if w6 is None:
    unknown += 1; print("[UNKNOWN] W6: brak aigon_mesh_duty_condition_ok{condition=\"w6\"} (executor mesh-duty nie eksportuje)")
else:
    print(f"[INFO] W6 (mesh-duty)={w6} — przeciążonych węzłów: {over}; W6 mierzy istnienie przeciążenia, ta bramka mierzy dispatch")
st = "FAIL" if fail else ("UNKNOWN" if unknown else "PASS")
print(f"STATUS: {st}")
sys.exit(0 if st == "PASS" else 1)
PY

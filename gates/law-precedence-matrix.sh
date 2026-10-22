#!/usr/bin/env bash
# law-precedence-matrix.sh — bramka M2 (LAW-PRECEDENCE-1, LAW-CONFLICT-1,
# LAW-STOP-1, LAW-PREAMBLE-1). Read-only, bez efektów ubocznych.
# Sprawdza: każde prawo z rejestru ma dokładnie jedno P0–P8, zgodność
# z warstwami, 10 par macierzy spójnych z resolution.order, 13 typów stopu,
# 8 zasad preambuły.
# Override ścieżek (testy negatywne): PRECEDENCE_FILE, REGISTRY_FILE.
# rc 0 = PASS, 1 = FAIL.
set -uo pipefail
ROOT="${AIGON_ROOT:-/opt/PROD}"
PRECEDENCE_FILE="${PRECEDENCE_FILE:-$ROOT/config/canonical/constitution-drafts/M2-precedence.yaml}"
REGISTRY_FILE="${REGISTRY_FILE:-$ROOT/config/canonical/constitution.generated.yaml}"

exec timeout 50 python3 - "$PRECEDENCE_FILE" "$REGISTRY_FILE" <<'PY'
import sys, yaml
pf, rf = sys.argv[1:3]
errs = []
def fail(m): errs.append(m)
try:
    p = yaml.safe_load(open(pf)); r = yaml.safe_load(open(rf))
except Exception as e:
    print(f"FAIL: wczytanie: {e}"); sys.exit(1)

laws = {l["id"]: l for l in r["laws"]}
ranks = {k: v.get("rank") for k, v in (r.get("layers") or {}).items()} if isinstance(r.get("layers"), dict) \
        else {x.get("id"): x.get("rank") for x in (r.get("layers") or [])}
LEVELS = [f"P{i}" for i in range(9)]
if list((p.get("p_levels") or {}).keys()) != LEVELS: fail("p_levels musi być dokładnie P0..P8 w kolejności")

pmap = {}
for lvl, ids in (p.get("law_p_map") or {}).items():
    if lvl not in LEVELS: fail(f"law_p_map: poziom {lvl} spoza P0..P8"); continue
    for i in ids or []:
        if i in pmap: fail(f"{i} przypisane dwa razy ({pmap[i]}, {lvl})")
        pmap[i] = lvl
missing = sorted(set(laws) - set(pmap)); extra = sorted(set(pmap) - set(laws))
if missing: fail(f"prawa bez P ({len(missing)}): {missing}")
if extra: fail(f"ID spoza rejestru w law_p_map: {extra}")
ext = p.get("external_laws") or {}
for k, v in ext.items():
    if v not in LEVELS: fail(f"external_laws.{k}={v} spoza P0..P8")
P = dict(pmap); P.update(ext)
pn = lambda i: int(P[i][1:])

lc = p.get("layer_constraints") or {}
for i, l in laws.items():
    if i not in pmap: continue
    if l.get("layer") == "omega" and pmap[i] not in lc.get("omega_allowed", []): fail(f"{i} (omega) w {pmap[i]} — dozwolone {lc.get('omega_allowed')}")
    if l.get("immutable") and pmap[i] not in lc.get("immutable_allowed", []): fail(f"{i} (immutable) w {pmap[i]}")
    if pmap[i] == "P0":
        rk = ranks.get(l.get("layer"))
        if rk is None or rk < lc.get("p0_min_layer_rank", 0): fail(f"{i} w P0 z warstwy {l.get('layer')} (rank {rk}) < {lc.get('p0_min_layer_rank')}")
fx = lc.get("fixed_exception") or []
if sorted(fx) != sorted(["LAW-Ω3","LAW-10","LAW-31"]): fail(f"fixed_exception musi być Ω3/10/31, jest {fx}")
for a in fx:
    for b in lc.get("fixed_exception_must_outrank") or []:
        if a in P and b in P and not pn(a) < pn(b): fail(f"fixed exception {a}({P[a]}) nie wyprzedza {b}({P[b]})")

pseudo = p.get("pseudo_parties") or {}
def expand(side):
    out = []
    for x in side:
        out += pseudo.get(x, [x])
    return out
cm = p.get("conflict_matrix") or []
if len(cm) != 10: fail(f"conflict_matrix ma {len(cm)} par, wymagane 10")
for c in cm:
    cid = c.get("id", "?")
    for f in ("a","b","winner","rule","test"):
        if not c.get(f): fail(f"{cid}: brak pola {f}")
    if c.get("winner") not in ("a","b"): fail(f"{cid}: winner musi być a|b"); continue
    try:
        A, B = expand(c["a"]), expand(c["b"])
        for i in A + B:
            if i not in P: raise KeyError(i)
    except KeyError as e:
        fail(f"{cid}: strona {e} bez P"); continue
    W, L = (A, B) if c["winner"] == "a" else (B, A)
    if min(pn(i) for i in W) > min(pn(i) for i in L):
        fail(f"{cid}: zwycięzca {W} (P{min(pn(i) for i in W)}) słabszy niż {L} (P{min(pn(i) for i in L)}) — sprzeczne z resolution.order")

SC = ["local","promotion","deploy_abort","immediate_rollback","global","emergency","resource",
      "retry","repair","cognitive","uncertainty","authority","irreversibility"]
st = p.get("stop_criteria") or {}
for k in SC:
    v = st.get(k)
    if not isinstance(v, dict) or not all(v.get(f) for f in ("trigger","action","resume")):
        fail(f"stop_criteria.{k}: brak trigger/action/resume")
if not (p.get("no_stop_loop") or {}).get("max_same_stop_without_new_evidence"): fail("no_stop_loop bez limitu")
pre = p.get("preamble") or []
if len(pre) != 8 or not all(x.get("principle") for x in pre): fail(f"preamble: wymagane 8 zasad, jest {len(pre)}")

if errs:
    print("FAIL:", *errs, sep="\n  "); sys.exit(1)
from collections import Counter
cnt = Counter(pmap.values())
print(f"PASS: {len(pmap)}/{len(laws)} praw z P (" + " ".join(f"{k}={cnt.get(k,0)}" for k in LEVELS) +
      f"); macierz {len(cm)}/10 spójna; stop {len(SC)}/13; preambuła {len(pre)}/8")
sys.exit(0)
PY

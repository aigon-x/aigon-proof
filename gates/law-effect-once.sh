#!/usr/bin/env bash
# tools/gates/law-effect-once.sh — S1-T2/T3 IDEMPOTENCY + EFFECT-ONCE.
#
# Efekt nieodwracalny (płatny SMS/telefon, mail zewnętrzny, oferta, deploy) bez
# klucza deduplikacji wydarzy się DRUGI raz przy pierwszym retry. Ta bramka
# zastępuje fasadę tools/verify/duplicate-idempotency-check.sh (GATE-097), która
# sprawdzała tylko obecność napisu „G133" w macierzy pokrycia.
#
# Read-only, statyczna: dla każdego wpisu inwentarza sprawdza, że effect_file
# i guard_file istnieją, a guard_file zawiera dowód deduplikacji (guard_regex).
# exit 0 = PASS, 1 = FAIL/ERROR (M1 executor_status).
#
#   EFFECT_INVENTORY  plik inwentarza (domyślnie config/canonical/constitution-drafts/S1-effect-inventory.yaml)
#   EFFECT_ROOT       korzeń ścieżek    (domyślnie /opt/PROD)
set -uo pipefail
ROOT_DEF="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EFFECT_ROOT="${EFFECT_ROOT:-$ROOT_DEF}"
EFFECT_INVENTORY="${EFFECT_INVENTORY:-$EFFECT_ROOT/config/canonical/constitution-drafts/S1-effect-inventory.yaml}"

[[ -f "$EFFECT_INVENTORY" ]] || { echo "ERROR law-effect-once: brak inwentarza $EFFECT_INVENTORY (reason=EVIDENCE_MISSING)"; exit 1; }

EFFECT_ROOT="$EFFECT_ROOT" EFFECT_INVENTORY="$EFFECT_INVENTORY" timeout 30 python3 - <<'PY'
import os, re, sys, yaml
root = os.environ["EFFECT_ROOT"]
try:
    inv = yaml.safe_load(open(os.environ["EFFECT_INVENTORY"])) or {}
except Exception as e:
    print(f"ERROR law-effect-once: inwentarz nieczytelny: {e}"); sys.exit(1)
effects = inv.get("effects") or []
if not effects:
    print("ERROR law-effect-once: inwentarz pusty — brak dowodu (reason=EVIDENCE_MISSING)"); sys.exit(1)
fails = 0
for e in effects:
    eid = e.get("id", "?")
    ef, gf, rx = e.get("effect_file"), e.get("guard_file"), e.get("guard_regex")
    if not (ef and gf and rx):
        print(f"  FAIL {eid}: wpis niekompletny (effect_file/guard_file/guard_regex)"); fails += 1; continue
    epath, gpath = os.path.join(root, ef), os.path.join(root, gf)
    if not os.path.isfile(epath):
        print(f"  FAIL {eid}: brak pliku efektu {ef}"); fails += 1; continue
    if not os.path.isfile(gpath):
        print(f"  FAIL {eid}: brak strażnika {gf}"); fails += 1; continue
    if re.search(rx, open(gpath, errors="replace").read()):
        print(f"  PASS {eid}: dedup w {gf}")
    else:
        print(f"  FAIL {eid}: brak klucza dedup w {gf} — {e.get('dedup_key','')}"); fails += 1
if fails:
    print(f"FAIL law-effect-once: {fails}/{len(effects)} efektów nieodwracalnych bez deduplikacji"); sys.exit(1)
print(f"PASS law-effect-once: {len(effects)}/{len(effects)} efektów z kluczem dedup")
PY
rc=$?; [[ $rc -eq 0 ]] && exit 0; exit 1

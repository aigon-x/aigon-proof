#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/law-estop.sh — S3-T5 / S3-T3 (rozszerza LAW-53: kill switch)
#
#  PRAWO: istnieje STOP-THE-WORLD (kill switch mesha), jest zakazany dla
#  agentów (forbidden — tylko operator), i jego działanie jest DOWIEDZIONE
#  cyklicznym drillem (nie deklaracją w kodzie).
#
#  POMIAR STRUKTURY (exit 0/1):
#    (1) trasa /api/v1/admin/kill w routerze runtime (api.rs);
#    (2) autonomy.yaml: admin_kill w klasie forbidden.
#  DRILL (informacyjnie, NIE wpływa na exit): artefakt drilla
#    artifacts/drills/estop-*.json młodszy niż 30 dni. Brak = UNKNOWN —
#    bramka read-only NIE odpala kill switcha na żywym meshu.
#  Override: LAW_ESTOP_ROOT. exit 0 = PASS, 1 = FAIL.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail
ROOT="${LAW_ESTOP_ROOT:-/srv/aigon}"
fail=0
if grep -qE 'route\("/api/v1/admin/kill"' "$ROOT/runtime/crates/aigon-runtime/src/api.rs" 2>/dev/null; then
  echo "[PASS] trasa /api/v1/admin/kill obecna w api.rs"
else echo "[FAIL] brak trasy kill switcha w api.rs"; fail=1; fi
cls=$(python3 - "$ROOT/config/autonomy.yaml" <<'PY' 2>/dev/null
import sys,yaml
d=yaml.safe_load(open(sys.argv[1])) or {}
for c in ("auto","accept","forbidden"):
    for g,items in (d.get(c) or {}).items():
        for it in items or []:
            if isinstance(it,dict) and "admin_kill" in it: print(c)
PY
)
if [ "$cls" = forbidden ]; then echo "[PASS] admin_kill w klasie forbidden (tylko operator)"
else echo "[FAIL] admin_kill w klasie '${cls:-BRAK}' — agent może zatrzymać świat"; fail=1; fi
d=$(find "$ROOT/artifacts/drills" -maxdepth 1 -name 'estop-*.json' -mtime -30 2>/dev/null | head -1)
if [ -n "$d" ]; then echo "[INFO] drill: PASS ($d)"
else echo "[INFO] drill: UNKNOWN — brak artefaktu artifacts/drills/estop-*.json < 30 dni (drill na żywym meshu poza zakresem bramki)"; fi
[ $fail -eq 0 ] && { echo "law-estop: PASS (struktura)"; exit 0; }
echo "law-estop: FAIL"; exit 1

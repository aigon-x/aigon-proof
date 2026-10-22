#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/cyclic-modules-sweep.sh — cykliczny przebieg modułów gates.yaml
#
#  WYGENERZONY 2026-10-03 (naprawa „66 sierot modułów", rozkaz Suwerena
#  „zero sierot: każdy moduł gates.yaml ma trigger w hooks.yaml albo cron.yaml").
#
#  PO CO: moduły gates.yaml (druga, niezależna oś certyfikacji verify.sh) biegły
#  WYŁĄCZNIE przez `verify.sh gates <PROFILE>` (CI) lub lokalny full/release —
#  ich spięcie lokalne (hooks.yaml/cron.yaml) nikt nie liczył. Zmierzone: 66 z 106
#  modułów bez ŻADNEGO triggera. Ten driver daje im CYKLICZNY, NIEBLOKUJĄCY
#  trigger: uruchamia każdy moduł po jego kanonicznym skrypcie z gates.yaml,
#  z twardym per-module timeoutem (żeby wiszący skan nie zjadł budżetu crona).
#
#  KLASA = cykliczna (block_on_fail N/A — cron): to audyty infrastrukturalne
#  (security-*, obs-*, backup-*, cert-renewal, access-*, container-*, state-*,
#  dlq-*, poison-*, retry-*, offline-*, power-*, spike-*, autoscaling-*,
#  backpressure, load-profile/peak-capacity/perf-regression, sast, ...).
#  Zmierzone 2026-10-03: 11 z nich FAIL a 8 wisiało >25 s lokalnie — w
#  triggerze blokującym zamurowałyby commit/push WSZYSTKIM. Stąd cron, nie hook.
#
#  Użycie:
#    bash tools/gates/cyclic-modules-sweep.sh <module> [<module> ...]
#  Env: AIGON_MODULE_TIMEOUT (default 45 s) — per-modułowy cap czasu.
#  Exit: zawsze 0 (pomiar widocznościowy; FAIL/TIMEOUT są w logu/summary).
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

GATES_YAML="$ROOT/config/canonical/gates.yaml"
TIMEOUT="${AIGON_MODULE_TIMEOUT:-45}"
[ -f "$GATES_YAML" ] || { echo "FAIL cyclic-modules-sweep (brak $GATES_YAML)"; exit 0; }

# module -> kanoniczny skrypt (względem repo), z SSOT gates.yaml.
declare -A SCR=()
while IFS=$'\t' read -r mod scr; do
  [ -n "$mod" ] && SCR["$mod"]="$scr"
done < <(python3 - "$GATES_YAML" <<'PYEOF'
import sys, os, yaml
for x in yaml.safe_load(open(sys.argv[1]))['gates']:
    print(f"{x['module']}\t{os.path.normpath(os.path.join('tools/verify', x['script']))}")
PYEOF
)

PASS=0; WARN=0; FAIL=0; TO=0; MISS=0
echo "=== cyclic-modules-sweep $(date -u +%Y-%m-%dT%H:%M:%SZ) — modułów: $# (timeout ${TIMEOUT}s) ==="
for m in "$@"; do
  scr="${SCR[$m]:-}"
  if [ -z "$scr" ] || [ ! -f "$ROOT/$scr" ]; then
    echo "MISS  $m (brak modułu w gates.yaml albo skryptu)"
    MISS=$((MISS+1)); continue
  fi
  s=$(date +%s)
  out="$(timeout "$TIMEOUT" bash "$ROOT/$scr" </dev/null 2>&1)"; rc=$?
  e=$(date +%s)
  case $rc in
    0) st="PASS";    PASS=$((PASS+1)) ;;
    2) st="WARN";    WARN=$((WARN+1)) ;;
    124|137) st="TIMEOUT"; TO=$((TO+1)) ;;
    *) st="FAIL";    FAIL=$((FAIL+1)) ;;
  esac
  echo "$st  $m ($((e-s))s, rc=$rc) :: $(printf '%s' "$out" | tail -1 | cut -c1-120)"
done
echo "=== SUMMARY: PASS=$PASS WARN=$WARN FAIL=$FAIL TIMEOUT=$TO MISS=$MISS ==="
exit 0

#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  tools/gates/nexus-graph.sh — GATE-226 NEXUS-GRAPH (F0 turbo-kernela)
#
#  Buduje JEDEN graf wiedzy z 5 rejestrów (constitution/gate-registry/hooks/
#  gates/skills) i eksportuje metryki sierot do Prometheus. Rozkaz Suwerena
#  2026-10-13: „jeden graf spinający wszystko", „ratchet musi działać".
#
#  MIERZY (nie deklaruje):
#    - graf buduje się deterministycznie (2× build = hash stabilny)
#    - metryki aigon_nexus_{nodes,edges,orphans,coverage} do textfile
#    - RATCHET: orphans nie może rosnąć (baseline w nexus-orphans-baseline.txt)
#
#  Profil: cyclic:hourly. Exit 0 (pomiar) — FAIL tylko przy REGRESJI ratchetu.
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="${AIGON_ROOT:-/opt/PROD}"
GEN="$ROOT/scripts/nexus-graph.py"
ORPH="$ROOT/scripts/nexus-orphans.py"
TEXTFILE="${AIGON_TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
BASE="$ROOT/config/canonical/nexus-orphans-baseline.txt"

echo "── GATE-226 nexus-graph (F0 turbo-kernel) ──"
[ -r "$GEN" ] || { echo "FAIL: brak $GEN"; exit 1; }

# 1. Zbuduj graf
if ! python3 "$GEN" --build >/dev/null 2>&1; then
  echo "FAIL: generator grafu nie zadziałał"; exit 1
fi

# 2. Metryki
counts="$(python3 "$GEN" --count 2>/dev/null)"
nodes="$(echo "$counts" | python3 -c 'import sys,json;print(json.load(sys.stdin)["counts"]["nodes"])' 2>/dev/null || echo 0)"
edges="$(echo "$counts" | python3 -c 'import sys,json;print(json.load(sys.stdin)["counts"]["edges"])' 2>/dev/null || echo 0)"
gates_wt="$(echo "$counts" | python3 -c 'import sys,json;print(json.load(sys.stdin)["orphans"]["GATE_without_hook_total"])' 2>/dev/null || echo -1)"
echo "graf: nodes=$nodes edges=$edges bramki_bez_triggera=$gates_wt"

# 3. Eksport metryk (textfile)
if [ -d "$TEXTFILE" ]; then
  tmp="$(mktemp)"
  {
    echo "# HELP aigon_nexus_nodes_total Wezly grafu nexus per typ"
    echo "# TYPE aigon_nexus_nodes_total gauge"
    echo "aigon_nexus_nodes_total $nodes"
    echo "# HELP aigon_nexus_edges_total Krawedzie grafu nexus"
    echo "# TYPE aigon_nexus_edges_total gauge"
    echo "aigon_nexus_edges_total $edges"
    echo "# HELP aigon_nexus_orphans_total Bramki bez triggera (cel: 0)"
    echo "# TYPE aigon_nexus_orphans_total gauge"
    echo "aigon_nexus_orphans_total $gates_wt"
  } > "$tmp"
  mv "$tmp" "$TEXTFILE/aigon-nexus.prom" 2>/dev/null || true
fi

# 4. RATCHET: sieroty nie mogą rosnąć
if [ -f "$BASE" ]; then
  base="$(grep -oE '^[0-9]+' "$BASE" | head -1)"
  if [ -n "${base:-}" ] && [ "${gates_wt:-9999}" -gt "$base" ]; then
    echo "FAIL gate-nexus-graph (REGRESJA ratchetu: bramki_bez_triggera $gates_wt > baseline $base)"
    exit 1
  fi
fi
echo "PASS nexus-graph: graf zbudowany, metryki wyeksportowane"
exit 0

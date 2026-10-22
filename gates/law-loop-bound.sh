#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/law-loop-bound.sh — S3-T6 (rozszerza LAW-50: brak pętli bez granic)
#
#  PRAWO: każda pętla nieskończona (`while true` / `while :`) w automatach
#  ma albo GRANICĘ (break/exit/return/timeout/limit prób), albo jest pętlą
#  demona TAKTOWANĄ `sleep` (obserwator co N s). Pętla bez żadnego z nich
#  = gorąca pętla bez granic (spin CPU, zalew logu, retry-storm).
#
#  POMIAR: ciało pętli = do 60 linii po nagłówku albo do `done` na tym
#  samym wcięciu. Override: LAW_LOOP_GLOB. exit 0 = PASS, 1 = FAIL.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail
GLOB="${LAW_LOOP_GLOB:-/srv/aigon/scripts/*.sh}"
fail=0; total=0
for f in $GLOB; do
  [ -f "$f" ] || continue
  case "$f" in *.bak*|*.pre-*) continue;; esac
  while IFS=: read -r ln res; do
    total=$((total+1))
    if [ "$res" = UNBOUNDED ]; then echo "[FAIL] $f:$ln — while-true bez sleep/break/exit/timeout"; fail=1; fi
  done < <(awk '
    function flush(){ if(open){ print start ":" (ok?"OK":"UNBOUNDED") } open=0 }
    /^[[:space:]]*while[[:space:]]+(true|:)[[:space:]]*;[[:space:]]*do/ {
      flush(); open=1; ok=0; start=NR; match($0,/^[[:space:]]*/); ind=RLENGTH; next }
    open {
      if ($0 ~ /(^|[^a-z_])(sleep|break|exit|return|timeout|inotifywait|read -t)([^a-z_]|$)/) ok=1
      match($0,/^[[:space:]]*/)
      if ($0 ~ /^[[:space:]]*done([[:space:];|&]|$)/ && RLENGTH==ind) flush()
      else if (NR-start>60) flush()
    }
    END{ flush() }' "$f")
done
echo "pętli nieskończonych zbadanych: $total"
[ $fail -eq 0 ] && { echo "law-loop-bound: PASS"; exit 0; }
echo "law-loop-bound: FAIL"; exit 1

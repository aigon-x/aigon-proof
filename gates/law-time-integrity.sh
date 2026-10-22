#!/usr/bin/env bash
# tools/gates/law-time-integrity.sh — S2-T2 TIME INTEGRITY.
#
# Leasy, TTL snapshotów (LAW-HEALTH-1), kolejność zdarzeń w ledgerze i okna
# dedup zakładają wspólny zegar. Nod z dryfem > progu kłamie o wieku dowodu.
#
# Read-only. Lokalnie: timedatectl NTPSynchronized=yes. Peery (równolegle, ssh
# ControlPath=none): NTPSynchronized + offset = zdalny `date` minus środek okna
# RTT; naruszenie, gdy |offset| - RTT/2 > TIME_MAX_OFFSET (dolna granica błędu).
# Nod nieosiągalny = pominięty z licznikiem; 0 zmierzonych peerów = ERROR.
# exit 0 = PASS, 1 = FAIL/ERROR.
#
#   TIME_NODES        aliasy ssh
#   TIME_MAX_OFFSET   sekundy (domyślnie 0.5)
#   TIME_FIXTURE      plik "node offset_s rtt_s sync(yes|no|down)" zamiast pomiaru
set -uo pipefail
NODES="${TIME_NODES:-prod-aigon contabo-aigon monitor-aigon site-aigon optiq-aigon kamil-aigon}"
MAX="${TIME_MAX_OFFSET:-0.5}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

if [[ -n "${TIME_FIXTURE:-}" ]]; then
  cp "$TIME_FIXTURE" "$T/res"
else
  ls=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo down)
  echo "local 0 0 ${ls:-down}" > "$T/n.local"
  for n in $NODES; do
    ( t0=$(date +%s.%N)
      out=$(timeout 12 ssh -o BatchMode=yes -o ConnectTimeout=5 -o ControlPath=none "$n" \
            'date +%s.%N; timedatectl show -p NTPSynchronized --value' 2>/dev/null)
      t1=$(date +%s.%N)
      r=$(sed -n 1p <<<"$out"); s=$(sed -n 2p <<<"$out")
      if [[ "$r" =~ ^[0-9]+\.[0-9]+$ ]]; then
        awk -v n="$n" -v r="$r" -v a="$t0" -v b="$t1" -v s="${s:-unknown}" \
          'BEGIN{printf "%s %.4f %.4f %s\n", n, r-(a+b)/2, b-a, s}' > "$T/n.$n"
      else
        echo "$n 0 0 down" > "$T/n.$n"
      fi ) &
  done
  wait
  cat "$T"/n.* > "$T/res"
fi

awk -v max="$MAX" '
  { o=$2<0?-$2:$2; lb=o-$3/2
    if ($4=="down") { down++; printf "  SKIP %s nieosiągalny\n",$1; next }
    meas++
    st="ok"; if ($4!="yes") { st="NTP-NIEZSYNC"; bad++ } else if (lb>max) { st="DRYF"; bad++ }
    printf "  %-14s offset=%+.4fs rtt=%.3fs ntp=%s %s\n",$1,$2,$3,$4,st }
  END {
    if (meas<2) { printf "ERROR law-time-integrity: zmierzono %d nodów (reason=DEPENDENCY_DOWN)\n", meas; exit 1 }
    if (bad)    { printf "FAIL law-time-integrity: %d/%d nodów poza integralnością czasu (próg %ss)\n", bad, meas, max; exit 1 }
    printf "PASS law-time-integrity: %d nodów w NTP, dryf <= %ss (pominięte: %d)\n", meas, max, down+0 }
' "$T/res"

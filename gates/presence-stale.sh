#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  presence-stale.sh — BRAMKA: rejestr obecności roju nie gnije
#
#  ROOT CAUSE (zmierzony 2026-10-01): mechanizm koordynacji roju
#  (scripts/aigon-agent-presence.sh) JEST opisany w AGENTS.md wszystkich
#  agentów (KANON 0-17), ale `gc` nie był wołany przez NIC — ani cron, ani
#  hook, ani reaktor. Skutek zmierzony: /var/lib/aigon/agent-presence/
#  nazbierał 533 MARTWE wpisy (pidy nie żyją, wiek do 284052 s = 3,3 dnia).
#  `check <ścieżka>` zwracał rc=1 na każdym zakresie, więc agenci BLOKOWALI
#  SIĘ NAWZAJEM — odwrotność celu „rój ma sobie nie przeszkadzać".
#  AGENTS.md obiecywał „zaległy wpis wygasa sam" — obietnica bez egzekucji
#  (klasa: napisane != działające).
#
#  CO MIERZY: ile wpisów obecności jest ZALEGŁYCH wg TEJ SAMEJ reguły,
#  którą stosuje `aigon-agent-presence.sh` (claim_is_live): pid żyje
#  (kill -0) ORAZ wiek <= TTL. Bramka nie wymyśla własnej definicji —
#  inaczej mierzyłaby co innego niż mechanizm, który pilnuje.
#
#  NAPRAWA (config/canonical/remediation.yaml): action = gc, verify = ta
#  bramka wraca do 0. Reaktor Bramkarza robi to sam (pętla ≤2 s).
#
#  Exit: 0 = PASS (0 zaległych), 1 = FAIL (>0 zaległych).
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

DIR="${AIGON_PRESENCE_DIR:-/var/lib/aigon/agent-presence}"
TTL="${AIGON_PRESENCE_TTL:-1800}"

if [ ! -d "$DIR" ]; then
  printf 'OK    rejestr obecnosci nie istnieje (%s) — nic do sprzatania\n' "$DIR"
  exit 0
fi

# PermissionError = proces ISTNIEJE (cudzy uid), brak uprawnien do sygnalu.
# Traktujemy go jako ZYWY — inaczej bramka oskarzalaby zywych agentow
# innych userow (root/aigon) o bycie duchem. To zmierzone: agenci na
# zdalnych nodach dzialaja jako root, a bramke odpala sniegul.
counts=$(python3 - "$DIR" "$TTL" <<'PY'
import json, os, sys, time
d, ttl = sys.argv[1], int(sys.argv[2])
now = time.time()
live = stale = 0
for f in os.listdir(d):
    if not f.endswith(".json"):
        continue
    p = os.path.join(d, f)
    try:
        pid = int((json.load(open(p)) or {}).get("pid") or 0)
    except Exception:
        stale += 1
        continue
    alive = False
    if pid:
        try:
            os.kill(pid, 0)
            alive = True
        except ProcessLookupError:
            alive = False
        except PermissionError:
            alive = True          # proces zyje, brak prawa sygnalu
    age = now - os.path.getmtime(p)
    if alive and age <= ttl:
        live += 1
    else:
        stale += 1
print(f"{live} {stale}")
PY
)
live=${counts% *}
stale=${counts#* }
total=$((live + stale))

if [ "$stale" -gt 0 ]; then
  printf 'FAIL  rejestr obecnosci: %s ZALEGLYCH z %s (zywi: %s) — gc nie byl wolany\n' \
    "$stale" "$total" "$live"
  exit 1
fi
printf 'OK    rejestr obecnosci czysty: %s wpisow, 0 zaleglych\n' "$total"
exit 0

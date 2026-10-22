#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
#  tools/gates/sterility.sh — delegat triggera dla bramki STERILE-001
#
#  PO CO (2026-09-23): STERILE-001 powstała na osi `tools/verify/` (verify.sh),
#  ale `gate-reachability` uznaje bramkę za lokalnie osiągalną TYLKO wtedy, gdy
#  jej NAZWA KOMENDY (basename bez .sh) występuje w liście `gates:` hooka:
#
#      base = os.path.basename(command)[:-3]      # "sterility"
#      is_local = base in trigger_gates           # hook entries
#
#  Bez takiego wpisu bramka liczyła się jako ci_only i ratchet pokrycia skoczył
#  20 -> 21 → `gate-reachability` FAIL → push zablokowany WSZYSTKIM agentom.
#  Wpisanie w hook `STERILE-001` (gate_id) NIE wystarcza — porównanie idzie po
#  nazwie komendy, nie po id. Stąd ten delegat: hook woła `sterility`, ten plik
#  przekazuje sterowanie do właściwej implementacji na osi verify.
#
#  Kontrakt bramki (zgodny z hook-runner.sh): 0 = PASS, 1 = FAIL, 2 = WARN.
# ══════════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMPL="$ROOT/tools/verify/structure/sterility.sh"

if [ ! -f "$IMPL" ]; then
  echo "[sterility] BRAK implementacji: $IMPL"
  exit 1
fi

exec bash "$IMPL" "$@"

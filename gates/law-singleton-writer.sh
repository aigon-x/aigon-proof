#!/usr/bin/env bash
# tools/gates/law-singleton-writer.sh — S2-T1 SPLIT-BRAIN (rozszerza LAW-22/29).
#
# Postgres mesha ma DOKŁADNIE jednego pisarza (primary = prod). Dwa primary =
# split-brain: dwa rozbieżne źródła prawdy i utrata zapisów przy scaleniu.
# Zero primary przy komplecie osiągalnych nodów = brak pisarza.
#
# Read-only: `select pg_is_in_recovery()` przez ssh (ControlPath=none, timeout),
# równolegle. Nod nieosiągalny NIE liczy się jako replika — jeśli przez to nie
# da się rozstrzygnąć (0 primary), wynik = ERROR/UNKNOWN, nigdy PASS.
# exit 0 = PASS, 1 = FAIL/ERROR.
#
#   SINGLETON_NODES    aliasy ssh (domyślnie 6 osiągalnych nodów; mail offline od 2026-08-28)
#   SINGLETON_LOCAL    1 = sprawdź też lokalny kontener (domyślnie 1)
#   SINGLETON_FIXTURE  plik "node t|f|down" zamiast pomiaru (test negatywny)
set -uo pipefail
NODES="${SINGLETON_NODES:-prod-aigon contabo-aigon monitor-aigon site-aigon optiq-aigon kamil-aigon}"
CT=aigon-datastores-postgres
Q='psql -U "${POSTGRES_USER:-postgres}" -tAc "select pg_is_in_recovery()"'

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
if [[ -n "${SINGLETON_FIXTURE:-}" ]]; then
  cp "$SINGLETON_FIXTURE" "$T/res"
else
  for n in $NODES; do
    ( v=$(timeout 15 ssh -o BatchMode=yes -o ConnectTimeout=5 -o ControlPath=none "$n" \
          "docker exec $CT sh -c '$Q'" 2>/dev/null | tr -d '[:space:]')
      [[ "$v" == t || "$v" == f ]] || v=down
      echo "$n $v" > "$T/n.$n" ) &
  done
  if [[ "${SINGLETON_LOCAL:-1}" == 1 ]]; then
    ( v=$(timeout 10 docker exec "$CT" sh -c "$Q" 2>/dev/null | tr -d '[:space:]')
      [[ "$v" == t || "$v" == f ]] || v=down
      echo "local $v" > "$T/n.local" ) &
  fi
  wait
  cat "$T"/n.* > "$T/res" 2>/dev/null
fi

prim=$(awk '$2=="f"{print $1}' "$T/res" | xargs)
np=$(awk '$2=="f"' "$T/res" | wc -l)
nr=$(awk '$2=="t"' "$T/res" | wc -l)
nd=$(awk '$2=="down"' "$T/res" | wc -l)
echo "  primary=[$prim] repliki=$nr nieosiągalne=$nd"
if (( np > 1 )); then
  echo "FAIL law-singleton-writer: SPLIT-BRAIN — $np primary: $prim"; exit 1
elif (( np == 1 )); then
  echo "PASS law-singleton-writer: dokładnie 1 pisarz ($prim), $nr replik"; exit 0
elif (( nd > 0 )); then
  echo "ERROR law-singleton-writer: 0 primary wśród osiągalnych, $nd nodów nieosiągalnych (reason=DEPENDENCY_DOWN)"; exit 1
else
  echo "FAIL law-singleton-writer: 0 primary — brak pisarza"; exit 1
fi

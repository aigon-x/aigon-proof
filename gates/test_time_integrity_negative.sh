#!/usr/bin/env bash
# Test negatywny S2-T2: zegary zgodne => PASS; dryf 3 s => FAIL; NTP wyłączony => FAIL;
# przywrócenie => PASS; brak pomiaru => ERROR. Fixture w mktemp -d.
set -uo pipefail
GATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/law-time-integrity.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
printf 'local 0 0 yes\nprod 0.010 0.200 yes\ncontabo -0.020 0.150 yes\n' > "$T/fx"; cp "$T/fx" "$T/orig"
export TIME_FIXTURE="$T/fx"
fail=0
"$GATE" >/dev/null; [[ $? -eq 0 ]] && echo "ok 1 zgodne zegary => PASS" || { echo "NOT OK 1"; fail=1; }
sed -i 's/^prod 0.010/prod 3.000/' "$T/fx"
"$GATE" >/dev/null; [[ $? -eq 1 ]] && echo "ok 2 dryf 3 s => FAIL" || { echo "NOT OK 2 dryf przepuszczony"; fail=1; }
cp "$T/orig" "$T/fx"; sed -i 's/^contabo \(.*\) yes/contabo \1 no/' "$T/fx"
"$GATE" >/dev/null; [[ $? -eq 1 ]] && echo "ok 3 NTP niezsynchronizowany => FAIL" || { echo "NOT OK 3"; fail=1; }
cp "$T/orig" "$T/fx"
"$GATE" >/dev/null; [[ $? -eq 0 ]] && echo "ok 4 przywrócony => PASS" || { echo "NOT OK 4"; fail=1; }
printf 'prod 0 0 down\ncontabo 0 0 down\n' > "$T/fx"
"$GATE" >/dev/null; [[ $? -eq 1 ]] && echo "ok 5 brak pomiaru => ERROR (nie PASS)" || { echo "NOT OK 5"; fail=1; }
exit $fail

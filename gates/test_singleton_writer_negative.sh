#!/usr/bin/env bash
# Test negatywny S2-T1: 1 primary => PASS; drugi primary (split-brain) => FAIL;
# przywrócenie => PASS; 0 primary + nod down => ERROR (nie PASS). Fixture w mktemp -d.
set -uo pipefail
GATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/law-singleton-writer.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
printf 'prod f\ncontabo t\nlocal t\n' > "$T/fx"; cp "$T/fx" "$T/orig"
export SINGLETON_FIXTURE="$T/fx"
fail=0
"$GATE" >/dev/null; [[ $? -eq 0 ]] && echo "ok 1 jeden pisarz => PASS" || { echo "NOT OK 1"; fail=1; }
sed -i 's/^contabo t/contabo f/' "$T/fx"
"$GATE" >/dev/null; [[ $? -eq 1 ]] && echo "ok 2 dwa primary => FAIL" || { echo "NOT OK 2 split-brain przepuszczony"; fail=1; }
cp "$T/orig" "$T/fx"
"$GATE" >/dev/null; [[ $? -eq 0 ]] && echo "ok 3 przywrócony => PASS" || { echo "NOT OK 3"; fail=1; }
printf 'prod down\ncontabo t\n' > "$T/fx"
"$GATE" >/dev/null; [[ $? -eq 1 ]] && echo "ok 4 primary nieosiągalny => ERROR (nie PASS)" || { echo "NOT OK 4"; fail=1; }
exit $fail

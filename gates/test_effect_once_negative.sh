#!/usr/bin/env bash
# Test negatywny S1-T2/T3: kopia efektu ze strażnikiem => PASS; usunięcie klucza
# dedup ze strażnika => FAIL; przywrócenie => PASS. Tylko kopia w mktemp -d.
set -uo pipefail
GATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/law-effect-once.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts"
printf '#!/bin/sh\n# IDEMPOTENCJA: dedup po hashu treści\ncurl -X POST https://example.invalid/sms\n' > "$T/scripts/sms.sh"
cp "$T/scripts/sms.sh" "$T/orig"
cat > "$T/inv.yaml" <<'EOF'
effects:
  - id: sms
    effect_file: scripts/sms.sh
    guard_file: scripts/sms.sh
    guard_regex: 'IDEMPOTENCJA'
EOF
export EFFECT_ROOT="$T" EFFECT_INVENTORY="$T/inv.yaml"
fail=0
"$GATE" >/dev/null; [[ $? -eq 0 ]] && echo "ok 1 strażnik obecny => PASS" || { echo "NOT OK 1"; fail=1; }
sed -i '/IDEMPOTENCJA/d' "$T/scripts/sms.sh"
"$GATE" >/dev/null; [[ $? -eq 1 ]] && echo "ok 2 brak klucza dedup => FAIL" || { echo "NOT OK 2 bramka przepuściła efekt bez dedup"; fail=1; }
cp "$T/orig" "$T/scripts/sms.sh"
"$GATE" >/dev/null; [[ $? -eq 0 ]] && echo "ok 3 przywrócony => PASS" || { echo "NOT OK 3"; fail=1; }
: > "$T/inv.yaml"
"$GATE" >/dev/null; [[ $? -eq 1 ]] && echo "ok 4 pusty inwentarz => ERROR (nie PASS)" || { echo "NOT OK 4"; fail=1; }
exit $fail

#!/usr/bin/env bash
# Test negatywny S2-T5: ponowienie z licznikiem => PASS; `until curl` bez licznika
# => FAIL; curl --retry 999 => FAIL; niepusty modelFallbacks => FAIL; przywrócenie
# => PASS. Tylko kopia w mktemp -d.
set -uo pipefail
GATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/law-retry-discipline.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts"
cat > "$T/scripts/ok.sh" <<'EOF'
#!/bin/sh
n=0
until curl -fsS https://example.invalid/h; do
  n=$((n+1)); [ "$n" -ge 5 ] && exit 1; sleep $((n*2))
done
curl --retry 3 https://example.invalid/x
EOF
cp "$T/scripts/ok.sh" "$T/orig"
echo '{"modelFallbacks": ""}' > "$T/qwen.json"
export TRY_ROOT="$T" TRY_PATHS=scripts TRY_QWEN_SETTINGS="$T/qwen.json"
fail=0
"$GATE" >/dev/null; [[ $? -eq 0 ]] && echo "ok 1 ograniczone ponowienia => PASS" || { echo "NOT OK 1"; fail=1; }
printf '#!/bin/sh\nuntil curl -fsS https://example.invalid/h; do sleep 1; done\n' > "$T/scripts/ok.sh"
"$GATE" >/dev/null; [[ $? -eq 1 ]] && echo "ok 2 until curl bez licznika => FAIL" || { echo "NOT OK 2"; fail=1; }
cp "$T/orig" "$T/scripts/ok.sh"; sed -i 's/--retry 3/--retry 999/' "$T/scripts/ok.sh"
"$GATE" >/dev/null; [[ $? -eq 1 ]] && echo "ok 3 curl --retry 999 => FAIL" || { echo "NOT OK 3"; fail=1; }
cp "$T/orig" "$T/scripts/ok.sh"; echo '{"modelFallbacks": "deepseek-chat"}' > "$T/qwen.json"
"$GATE" >/dev/null; [[ $? -eq 1 ]] && echo "ok 4 modelFallbacks niepusty => FAIL" || { echo "NOT OK 4"; fail=1; }
echo '{"modelFallbacks": ""}' > "$T/qwen.json"
"$GATE" >/dev/null; [[ $? -eq 0 ]] && echo "ok 5 przywrócony => PASS" || { echo "NOT OK 5"; fail=1; }
exit $fail

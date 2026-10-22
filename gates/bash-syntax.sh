#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/bash-syntax.sh — gate bash-syntax (hook-runner)
#
#  Wydzielony z case'a hook-runner.sh (digital twin 2026-09-05).
#  bash -n na kluczowych skryptach pipeline'u — składnia musi być poprawna,
#  bo hook-runner/ci-deploy odpalają się przy KAŻDYM commit/push.
#
#  Kontrakt: exit 0 = PASS, exit 1 = FAIL (błąd składni).
#  Zmienne env: AIGON_BS_FILES (lista plików, default 3 kluczowe).
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

FILES="${AIGON_BS_FILES:-$ROOT/scripts/pipeline.sh $ROOT/scripts/ci-deploy.sh $ROOT/scripts/hook-runner.sh}"
BAD=""
for f in $FILES; do
  bash -n "$f" 2>/dev/null || BAD="$BAD $f"
done
if [ -z "$BAD" ]; then
  echo "bash-syntax: PASS (składnia OK)"
  exit 0
fi
echo "bash-syntax: FAIL (błąd składni:$BAD)"
exit 1

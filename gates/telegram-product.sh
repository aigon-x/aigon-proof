#!/usr/bin/env bash
# GATE-147: scoped immutable artifact or actual two-origin rollout proof.
# This gate performs measurements, never retag/recreate/provider operations.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 1
phase="${AIGON_TELEGRAM_DEPLOY_PHASE:-}"
case "${AIGON_HOOK_TRIGGER:-}" in
  product:telegram:artifact) required_phase=artifact_loaded_only ;;
  product:telegram:deploy) required_phase=active_rollout ;;
  '') required_phase="$phase" ;;
  *) echo 'UNKNOWN telegram-product: unsupported invocation context; denied'; exit 1 ;;
esac
if [ -n "$phase" ] && [ "$phase" != "$required_phase" ]; then
  echo 'UNKNOWN telegram-product: phase contradicts canonical hook; denied'
  exit 1
fi
phase="$required_phase"
pins="${AIGON_TELEGRAM_DEPLOY_PINS:-}"
case "$phase" in artifact_loaded_only|active_rollout) ;; *) echo 'UNKNOWN telegram-product: explicit typed phase required; denied'; exit 1 ;; esac
if [ -z "$pins" ] || [ ! -f "$pins" ] || [ -L "$pins" ]; then
  echo 'UNKNOWN telegram-product: regular immutable pin document required; denied'
  exit 1
fi
for tool in python3 timeout mktemp; do
  command -v "$tool" >/dev/null 2>&1 || { echo 'UNKNOWN telegram-product: required tool absent; denied'; exit 1; }
done
for source in product_gate.py deploy_context.py rollout_verify.py; do
  if [ ! -f "$ROOT/products/companion/$source" ] || [ -L "$ROOT/products/companion/$source" ]; then
    echo 'UNKNOWN telegram-product: approved verifier source absent/ambiguous; denied'
    exit 1
  fi
done
home="$ROOT/reports/telegram-gates"
[ ! -L "$home" ] || { echo 'UNKNOWN telegram-product: unsafe evidence home; denied'; exit 1; }
mkdir -p "$home" || exit 1
umask 077
evidence="$(mktemp "$home/product-proof.XXXXXXXX.json")" || exit 1
if timeout --signal=TERM --kill-after=5s 290s python3 -B "$ROOT/products/companion/product_gate.py" \
  --phase "$phase" --pins "$pins" > "$evidence"; then
  verifier_rc=0
else
  verifier_rc=$?
fi
if [ "$verifier_rc" -ne 0 ]; then
  echo "UNKNOWN/FAIL telegram-product: verifier exit=$verifier_rc; denied; retained=$evidence"
  exit 1
fi
# Exit0 alone is not proof: reject empty/truncated/wrong-phase/false/replayed
# envelopes. Actual fingerprint freshness and scope are validated upstream.
if ! python3 - "$evidence" "$phase" <<'PY'
import json,sys
try:
    document=json.load(open(sys.argv[1]))
    assert type(document) is dict
    assert document.get('verified') is True
    assert document.get('role')=='additive_product_gate'
    assert document.get('phase')==sys.argv[2]
    assert document.get('receipt_scope')==sys.argv[2]
    assert document.get('global_policy_exemption') is False
    assert type(document.get('failures')) is list and not document['failures']
    assert type(document.get('producer')) is dict
    assert type(document.get('loaded')) is list and len(document['loaded'])==2
except Exception:
    raise SystemExit(1)
PY
then
  echo "UNKNOWN telegram-product: invalid or contradictory evidence; denied; retained=$evidence"
  exit 1
fi
echo "PASS telegram-product phase=$phase retained=$evidence; no global-runtime or genuine-owner-delivery claim"

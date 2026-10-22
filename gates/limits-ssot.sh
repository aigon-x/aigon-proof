#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  limits-ssot.sh — GATE: config/limits.yaml == SSOT (LAW-20)
#
#  Sprawdza, że config/limits.yaml (limity runtime) zgadza się ze źródłem
#  prawdy. Fail-closed: brak pliku / nieparsowalny = FAIL. Brak baseline'u
#  do porównania = WARN (nie udajemy zielonego).
#
#  Exit: 0=PASS  1=FAIL  2=WARN
# ═══════════════════════════════════════════════════════════════════════════
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIMITS="${ROOT}/config/limits.yaml"
SSOT="${ROOT}/config/agent-models.yaml"

[ -f "$LIMITS" ] || { echo "FAIL: brak $LIMITS"; exit 1; }

if ! timeout 15 python3 -c "import yaml,sys; yaml.safe_load(open('$LIMITS'))" 2>/dev/null; then
  echo "FAIL: $LIMITS nie jest poprawnym YAML"; exit 1
fi

# Kluczowe limity — muszą istnieć w limits.yaml (konieczne pola).
MISSING=0
for k in num_ctx num_parallel max_loaded_models; do
  grep -qE "^[[:space:]]*${k}:" "$LIMITS" || { echo "WARN: brak klucza '$k' w limits.yaml"; MISSING=1; }
done

# Baseline do porównania (jeśli jest) — inaczej WARN (nie zweryfikowano zgodności).
BASELINE="${ROOT}/config/canonical/limits.baseline.sha256"
if [ -f "$BASELINE" ]; then
  if echo "$(sha256sum "$LIMITS" | awk '{print $1}')" | cmp -s - "$BASELINE"; then
    echo "PASS: limits.yaml zgodny z baseline SSOT"
    exit 0
  else
    echo "FAIL: limits.yaml rozjechał się z baseline SSOT ($BASELINE)"
    exit 1
  fi
fi

[ "$MISSING" = "1" ] && { echo "WARN: limits.yaml jest, ale brak kluczowych pól i brak baseline'u — zgodność z SSOT NIEZWERYFIKOWANA"; exit 2; }
echo "WARN: limits.yaml jest i parsuje się, ale brak baseline'u do potwierdzenia zgodności z SSOT"
exit 2

#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/mesh-absorb.sh — gate mesh-absorb (hook-runner)
#
#  AUTOMAT: „manifest mesha jest LUSTREM config/mesh-nodes.yaml (SSOT),
#  a konfiguracje agentów propagują się na mesh zgodnie z agent-models.yaml".
#  Weryfikacja wyłącznie przez DRY-RUNY generatorów (idempotentne, zero
#  zapisów, zero SSH) — mesh-sync.sh wymaga SSH key auth, za ciężkie i za
#  ryzykowne dla hooka:
#    1. config/mesh-nodes.yaml (SSOT) istnieje i zawiera >= 8 peerów
#       (grep '^\s*ip:') — absorb wymaga pełnej obecności nodów.
#    2. scripts/sync-mesh-manifest.py --dry-run → exit 0 i „OK manifest
#       zgodny" — runtime/manifests/mesh.yaml (config/mesh.yaml to symlink)
#       nie rozjechał się od SSOT. Rozjazd = FAIL.
#    3. scripts/sync-agent-models.py --dry-run → exit 0 (propagacja
#       agent-models.yaml do configów agentów). Niezerowy exit = WARN:
#       propagacja częściowa (np. nieczytelny token MCP dla nie-aigon),
#       a CHG qwen baseUrl to domena Agent-A — cron (*/15) i tak wykona.
#
#  Kontrakt z hook-runner.sh:
#    exit 0 = PASS
#    exit 1 = FAIL (brak SSOT, manifest niezgodny, < 8 peerów)
#    exit 2 = WARN (propagacja agentów niespójna — diagnoza, nie blokuje)
#
#  Zmienne env do testów: AIGON_MA_NODES (mesh-nodes.yaml),
#  AIGON_MA_SYNC_MANIFEST, AIGON_MA_SYNC_MODELS (skrypty), AIGON_MA_MIN_PEERS.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NODES="${AIGON_MA_NODES:-$ROOT/config/mesh-nodes.yaml}"
SYNC_MANIFEST="${AIGON_MA_SYNC_MANIFEST:-$ROOT/scripts/sync-mesh-manifest.py}"
SYNC_MODELS="${AIGON_MA_SYNC_MODELS:-$ROOT/scripts/sync-agent-models.py}"
MIN_PEERS="${AIGON_MA_MIN_PEERS:-8}"

[ -f "$NODES" ] || { echo "mesh-absorb: FAIL — brak SSOT config/mesh-nodes.yaml: $NODES"; exit 1; }
[ -f "$SYNC_MANIFEST" ] || { echo "mesh-absorb: FAIL — brak generatora manifestu: $SYNC_MANIFEST"; exit 1; }
[ -f "$SYNC_MODELS" ] || { echo "mesh-absorb: FAIL — brak generatora configów agentów: $SYNC_MODELS"; exit 1; }

# ── 1. Obecność nodów (SSOT) ──────────────────────────────────────────
PEERS="$(grep -cE '^\s*ip:' "$NODES" 2>/dev/null || echo 0)"
if [ "${PEERS:-0}" -lt "$MIN_PEERS" ]; then
  echo "mesh-absorb: FAIL — config/mesh-nodes.yaml zawiera $PEERS peerów (oczekiwano >= $MIN_PEERS) — absorb niepełny"
  exit 1
fi

# ── 2. Lustro manifestu (SSOT → runtime/manifests/mesh.yaml) ──────────
MANIFEST_OUT="$(python3 "$SYNC_MANIFEST" --dry-run 2>&1)"
MANIFEST_RC=$?
if [ $MANIFEST_RC -ne 0 ]; then
  echo "mesh-absorb: FAIL — sync-mesh-manifest.py --dry-run exit=$MANIFEST_RC — manifest rozjechany od SSOT:"
  echo "$MANIFEST_OUT" | sed 's/^/    /'
  exit 1
fi
case "$MANIFEST_OUT" in
  *"OK"*) : ;;
  *)
    echo "mesh-absorb: FAIL — sync-mesh-manifest.py --dry-run nie potwierdza zgodności:"
    echo "$MANIFEST_OUT" | sed 's/^/    /'
    exit 1
    ;;
esac

# ── 3. Propagacja configów agentów (agent-models.yaml → agenci) ───────
MODELS_OUT="$(python3 "$SYNC_MODELS" --dry-run 2>&1)"
MODELS_RC=$?
if [ $MODELS_RC -ne 0 ]; then
  echo "mesh-absorb: WARN — sync-agent-models.py --dry-run exit=$MODELS_RC — propagacja częściowa (CHG qwen baseUrl = domena Agent-A; cron */15 wykona; token MCP nieczytelny dla nie-aigon to WARN nie FAIL):"
  echo "$MODELS_OUT" | tail -5 | sed 's/^/    /'
  exit 2
fi

echo "mesh-absorb: PASS — SSOT peerów=$PEERS, manifest zgodny z mesh-nodes.yaml, propagacja agent-models.yaml OK (dry-run)"
exit 0

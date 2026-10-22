#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/cerberus-e2e.sh — gate cerberus-e2e (hook-runner)
#
#  AUTOMAT: „pełny pipeline testów E2E (CERBERUS guard tests) — zielony".
#  W hooku NIE uruchamiamy pełnego pipeline'u:
#    - cerberus-e2e-pipeline.sh wymaga sudo (aigon: (ALL:ALL) ALL z
#      timestamp_timeout=60, BEZ NOPASSWD) — nie-interaktywne sudo w hooku
#      zawiedzie, a zapis do PIPELINE_DIR (NFS, root-owned) też wymaga praw;
#    - cargo build+test całego runtime to minuty — za drogo na pre-push.
#  Gate weryfikuje ARTEFAKT ostatniego przebiegu (uczciwy dowód, nie założenie):
#    - runtime/tools/cerberus-e2e-pipeline.sh istnieje (pipeline jest w repo);
#    - /mnt/nas-aigonfs/aigon-x/pipeline/cerberus-e2e/latest.summary istnieje
#      i ma status=pass, failed=0, test_count>0;
#    - przebieg jest ŚWIEŻY (< 24h wg mtime) — nieświeży = WARN, nie FAIL
#      (severity tego gate'u w profilu full to WARNING — patrz gates.yaml).
#  Pełny przebieg tylko na żądanie: AIGON_CERBERUS_FULL=1 (opcja operacyjna,
#  np. cron release) — z RUNTIME_DIR=/opt/PROD/runtime i timeoutem 600s.
#
#  Kontrakt z hook-runner.sh:
#    exit 0 = PASS
#    exit 1 = FAIL (brak skryptu pipeline, artefakt z failed>0 / status!=pass)
#    exit 2 = WARN (brak danych, nieświeże, lub pełny przebieg niewykonalny)
#
#  Zmienne env do testów: AIGON_CE_PIPELINE (skrypt pipeline),
#  AIGON_CE_SUMMARY (ścieżka latest.summary).
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PIPELINE="${AIGON_CE_PIPELINE:-$ROOT/runtime/tools/cerberus-e2e-pipeline.sh}"
SUMMARY="${AIGON_CE_SUMMARY:-/mnt/nas-aigonfs/aigon-x/pipeline/cerberus-e2e/latest.summary}"

if [ ! -f "$PIPELINE" ]; then
  # Kontrakt (poprawiony 2026-09-23): brak skryptu pipeline w PLATFORMIE = FAIL (1).
  # W repo PRODUKTU pipeline cerberus należy do platformy i nie istnieje z definicji
  # (brak .scaffold/project-manifest.yaml = to platforma) → NOT_APPLICABLE (3),
  # bo brak wejścia to nie porażka bramki.
  if [ ! -f "$ROOT/.scaffold/project-manifest.yaml" ]; then
    echo "cerberus-e2e: FAIL — brak skryptu pipeline: $PIPELINE"
    exit 1
  fi
  echo "cerberus-e2e: NOT_APPLICABLE — pipeline cerberus należy do platformy ($PIPELINE)"
  exit 3
fi

# ── Pełny przebieg tylko na żądanie (opcja operacyjna, nie hook) ──────
if [ "${AIGON_CERBERUS_FULL:-0}" = "1" ]; then
  RUNTIME_DIR="$ROOT/runtime" timeout 600 bash "$PIPELINE" >/dev/null 2>&1
  RC=$?
  if [ $RC -eq 0 ]; then
    echo "cerberus-e2e: PASS — pełny pipeline zakończony (RUNTIME_DIR=$ROOT/runtime)"
    exit 0
  fi
  echo "cerberus-e2e: FAIL — pełny pipeline exit=$RC (RUNTIME_DIR=$ROOT/runtime)"
  exit 1
fi

# ── Weryfikacja artefaktu ostatniego przebiegu ─────────────────────────
if [ ! -f "$SUMMARY" ]; then
  echo "cerberus-e2e: WARN — brak artefaktu $SUMMARY (pipeline nigdy nie zapisał wyniku na NFS); pełny przebieg wymaga AIGON_CERBERUS_FULL=1 z sudo"
  exit 2
fi

[ -r "$SUMMARY" ] || { echo "cerberus-e2e: WARN — artefakt $SUMMARY nieczytelny (uprawnienia NFS)"; exit 2; }

STATUS="$(grep -E '^status=' "$SUMMARY" 2>/dev/null | cut -d= -f2- | tr -d ' \r')"
PASSED="$(grep -E '^passed=' "$SUMMARY" 2>/dev/null | cut -d= -f2- | tr -d ' \r')"
FAILED="$(grep -E '^failed=' "$SUMMARY" 2>/dev/null | cut -d= -f2- | tr -d ' \r')"
TEST_COUNT="$(grep -E '^test_count=' "$SUMMARY" 2>/dev/null | cut -d= -f2- | tr -d ' \r')"
TIMESTAMP="$(grep -E '^timestamp=' "$SUMMARY" 2>/dev/null | cut -d= -f2- | tr -d ' \r')"

if [ -z "$STATUS" ]; then
  echo "cerberus-e2e: WARN — $SUMMARY bez pola status= (uszkodzony artefakt)"
  exit 2
fi

[ "$STATUS" = "pass" ] || { echo "cerberus-e2e: FAIL — ostatni przebieg status=$STATUS (oczekiwano pass); $SUMMARY"; exit 1; }
[ "${FAILED:-0}" = "0" ] || { echo "cerberus-e2e: FAIL — ostatni przebieg failed=$FAILED; $SUMMARY"; exit 1; }

# Świeżość: mtime artefaktu < 24h. Nieświeży wynik to WARN (brak dowodu, że
# obecny kod przechodzi), nie blokada — severity gate'u to WARNING.
MTIME="$(stat -c %Y "$SUMMARY" 2>/dev/null || echo 0)"
NOW="$(date +%s)"
if [ "$MTIME" -gt 0 ] && [ $((NOW - MTIME)) -gt 86400 ]; then
  echo "cerberus-e2e: WARN — artefakt NIEŚWIEŻY (>24h, mtime=$(date -d @"$MTIME" '+%Y-%m-%d_%H:%M:%S' 2>/dev/null)); pipeline nie był uruchamiany od tego czasu"
  exit 2
fi

echo "cerberus-e2e: PASS — artefakt $STATUS (passed=${PASSED:-?}, failed=${FAILED:-0}, test_count=${TEST_COUNT:-?}, timestamp=${TIMESTAMP:-?})"
exit 0

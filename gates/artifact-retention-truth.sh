#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
#  tools/gates/artifact-retention-truth.sh — BRAMKA RETENCJI ARTEFAKTÓW
#
#  PO CO (zmierzone 2026-10-19, DiskGuardCritical: / 95%, 53 GB wolne):
#  1. /opt/PROD/artifacts: build-knowledge-capsule.sh zostawiał ROZPAKOWANY
#     katalog OBOK archiwum .tar.zst — 31 dni x ~1,4 GB = 13,3 GB duplikatu.
#  2. /opt/PROD/datastores/surrealdb/data: backup-datastores.sh stage'ował
#     export na sshfs NAS; `mv` 5,8 GB nie kończył się → `set -e` przerywał
#     funkcję, a surowe .surql zostawało w ŻYWYM katalogu danych (3,2 GB +
#     5,8 GB = 8,9 GB).
#  ŻADNA bramka tego nie mierzyła: disk-guard pilnuje tylko % zajętości
#  i woła reclaim (cache/logi), więc wzrost DANYCH był dla niego niewidzialny.
#
#  KONTRAKT: 0 = PASS, 2 = DEFEKT (zmierzone naruszenie), 3 = BRAK POMIARU.
#  --selftest: dowód negatywny (sabotaż → DEFEKT), bez niego bramka nie istnieje.
# ══════════════════════════════════════════════════════════════════════════
set -uo pipefail

ART="${AIGON_ARTIFACTS_DIR:-/opt/PROD/artifacts}"
SURREAL_DATA="${AIGON_SURREAL_DATA_DIR:-/opt/PROD/datastores/surrealdb/data}"
MOUNT="${AIGON_DISK_GUARD_MOUNT:-/}"
MAX_EXPANDED=0          # rozpakowanych kapsuł może być 0 (archiwum jest artefaktem)
WARN_PCT="${AIGON_ARTIFACT_RETENTION_WARN_PCT:-85}"
FAIL_PCT="${AIGON_ARTIFACT_RETENTION_FAIL_PCT:-94}"   # = próg alertu DiskGuardCritical

problems=0
measure() {
  echo "-- ART=$ART SURREAL_DATA=$SURREAL_DATA"
  # C1: rozpakowane kapsuły obok archiwum = duplikat
  local expanded=0 d
  for d in "$ART"/aigon-knowledge-capsule-*/; do
    [ -d "$d" ] || continue
    expanded=$((expanded+1))
    echo "   C1 rozpakowana kapsula: ${d%/}"
  done
  if [ "$expanded" -gt "$MAX_EXPANDED" ]; then
    echo "C1 DEFEKT: rozpakowanych kapsuł=$expanded (limit=$MAX_EXPANDED) — archiwum .tar.zst jest artefaktem, katalog to duplikat"
    problems=$((problems+1))
  else
    echo "C1 OK: rozpakowanych kapsuł=$expanded"
  fi

  # C2: surowe exporty SurrealDB zalegające w żywym katalogu danych (>24h)
  local stale=0 f
  if [ -d "$SURREAL_DATA" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      stale=$((stale+1))
      echo "   C2 zaległy eksport: $(basename "$f") ($(du -h "$f" 2>/dev/null | cut -f1))"
    done < <(find "$SURREAL_DATA" -maxdepth 1 -type f -name '.aigon-surrealdb-export-*.surql' -mtime +0 2>/dev/null)
    if [ "$stale" -gt 0 ]; then
      echo "C2 DEFEKT: zaległych exportów=$stale — staging musi być lokalny, /data nie jest miejscem na kopie"
      problems=$((problems+1))
    else
      echo "C2 OK: brak zaległych exportów .surql >24h"
    fi
  else
    echo "C2 BRAK POMIARU: nie ma $SURREAL_DATA"
    return 3
  fi

  # C3: zajętość dysku — próg wczesnego ostrzegania (disk-guard pali się później)
  local pct
  pct="$(df --output=pcent "$MOUNT" 2>/dev/null | tail -1 | tr -dc '0-9')"
  if [ -z "$pct" ]; then
    echo "C3 BRAK POMIARU: df $MOUNT nie zwrócił procentu"
    return 3
  fi
  if [ "$pct" -ge "$FAIL_PCT" ]; then
    echo "C3 DEFEKT: ${MOUNT} zajęty ${pct}% (próg ${FAIL_PCT}%)"
    problems=$((problems+1))
  elif [ "$pct" -ge "$WARN_PCT" ]; then
    echo "C3 WARN: ${MOUNT} zajęty ${pct}% (próg ostrzegawczy ${WARN_PCT}%)"
  else
    echo "C3 OK: ${MOUNT} zajęty ${pct}%"
  fi
  [ "$problems" -eq 0 ] && return 0 || return 2
}

if [ "${1:-}" = "--selftest" ]; then
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/art" "$tmp/surreal"
  # stan zdrowy: archiwum bez katalogu, brak exportów
  : > "$tmp/art/aigon-knowledge-capsule-20260101.tar.zst"
  out="$(ART="$tmp/art" SURREAL_DATA="$tmp/surreal" measure 2>&1)"; rc=$?
  echo "$out" | grep -q 'C1 OK' && [ "$rc" -eq 0 ] \
    && { echo "SELFTEST 1/3 PASS: stan zdrowy → PASS (rc=0)"; } \
    || { echo "SELFTEST 1/3 FAIL: stan zdrowy nie dał PASS (rc=$rc)"; exit 1; }
  # sabotaż 1: rozpakowany katalog kapsuły
  mkdir -p "$tmp/art/aigon-knowledge-capsule-20260102"
  out="$(ART="$tmp/art" SURREAL_DATA="$tmp/surreal" measure 2>&1)"; rc=$?
  echo "$out" | grep -q 'C1 DEFEKT' && [ "$rc" -eq 2 ] \
    && { echo "SELFTEST 2/3 PASS: rozpakowana kapsuła → DEFEKT (rc=2)"; } \
    || { echo "SELFTEST 2/3 FAIL: sabotaż C1 nie wykryty (rc=$rc)"; exit 1; }
  # sabotaż 2: zaległy eksport starszy niż doba
  : > "$tmp/surreal/.aigon-surrealdb-export-runtime-20260101-000000.surql"
  touch -d '2026-01-01' "$tmp/surreal/.aigon-surrealdb-export-runtime-20260101-000000.surql"
  out="$(ART="$tmp/art" SURREAL_DATA="$tmp/surreal" measure 2>&1)"; rc=$?
  echo "$out" | grep -q 'C2 DEFEKT' && [ "$rc" -eq 2 ] \
    && { echo "SELFTEST 3/3 PASS: zaległy eksport → DEFEKT (rc=2)"; } \
    || { echo "SELFTEST 3/3 FAIL: sabotaż C2 nie wykryty (rc=$rc)"; exit 1; }
  echo "artifact-retention-truth: SELFTEST PASS (3/3)"; exit 0
fi

measure; rc=$?
case "$rc" in
  0) echo "artifact-retention-truth: PASS (retencja artefaktów w normie)";;
  2) echo "artifact-retention-truth: DEFEKT (zmierzone naruszenie retencji)";;
  *) echo "artifact-retention-truth: BRAK POMIARU — nie ogłaszam zieleni";;
esac
exit "$rc"

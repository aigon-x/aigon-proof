#!/usr/bin/env bash
# GATE-338 — LAW-SOVEREIGN-REPORT-1: raport ma KONTRAKT i ARTEFAKT.
#
# Co mierzy (statycznie, bez wykonywania kodu z JSON):
#   1. kontrakt raportu istnieje i jest w wersji 2,
#   2. kontrakt zawiera pola wymagane przez finalizer,
#   3. finalizer istnieje (tools/gates/constitution-contract.sh),
#   4. w reports/ istnieje co najmniej jeden artefakt raportu.
# To NIE jest dowód, że każda tura miała raport (to mierzy ledger/inspekcja);
# to jest dowód, że MECHANIZM raportu jest kompletny i podpięty.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

sprawdz() {
  local kontrakt="$1" finalizer="$2" raporty="$3"
  [ -f "$kontrakt" ] || { echo "FAIL sovereign-report-guard: brak kontraktu $kontrakt"; return 1; }
  grep -Eq '^schema_version:[[:space:]]*2[[:space:]]*$' "$kontrakt" \
    || { echo "FAIL sovereign-report-guard: kontrakt != v2"; return 1; }
  local pole
  for pole in mission_id constitution_verdict evidence_set; do
    grep -q "$pole" "$kontrakt" \
      || { echo "FAIL sovereign-report-guard: kontrakt bez pola $pole"; return 1; }
  done
  [ -f "$finalizer" ] \
    || { echo "FAIL sovereign-report-guard: brak finalizera $finalizer"; return 1; }
  local ile
  ile="$(rg --files "$raporty" -g '*sovereign*' -g '*constitution*' 2>/dev/null | wc -l)"
  [ "$ile" -gt 0 ] \
    || { echo "FAIL sovereign-report-guard: brak artefaktu raportu w $raporty"; return 1; }
  echo "PASS sovereign-report-guard: kontrakt v2 + finalizer + artefakty=$ile"
  return 0
}

if [ "${1:-}" = "--selftest" ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/config/canonical" "$tmp/tools/gates" "$tmp/reports"
  printf 'schema_version: 2\nfinal_fields: [mission_id, constitution_verdict, evidence_set]\n' \
    > "$tmp/config/canonical/constitution-report-contract.yaml"
  : > "$tmp/tools/gates/constitution-contract.sh"
  echo "raport" > "$tmp/reports/sovereign-report-test.md"
  sprawdz "$tmp/config/canonical/constitution-report-contract.yaml" \
          "$tmp/tools/gates/constitution-contract.sh" "$tmp/reports" \
    || exit 1
  rm -f "$tmp/reports/sovereign-report-test.md"
  if sprawdz "$tmp/config/canonical/constitution-report-contract.yaml" \
             "$tmp/tools/gates/constitution-contract.sh" "$tmp/reports" >/dev/null 2>&1; then
    echo "FAIL sovereign-report-guard: selftest — brak raportu zaakceptowany"
    exit 1
  fi
  echo "PASS sovereign-report-guard: selftest (brak raportu wykryty)"
  exit 0
fi

sprawdz "$ROOT/config/canonical/constitution-report-contract.yaml" \
        "$ROOT/tools/gates/constitution-contract.sh" \
        "$ROOT/reports"

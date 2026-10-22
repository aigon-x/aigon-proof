#!/usr/bin/env bash
# quality-gate-manifest.sh — adapter bramki egzekwującej KANON skilli quality-gate.
# Kontrakt hook-runner: bramki wołane jako tools/gates/<id>.sh, exit 0=PASS 1=FAIL 2=env.
#
# ROZKAZ SUWERENA 2026-10-02: „zobacz czy to jest do kanonu dodane i manifestu
# te skille; jesli nie to musi sie to automatycznie dziac". Zmierzone: skill
# perfect-magic-awesome-quality-gate istnieje w skills/shared/ i w grafach
# (skill-graph/exec-graph), ALE nie mial ZADNEJ egzekucji przy pushu — sama
# rejestracja to deklaracja, nie straznik (LAW-6: jedno zrodlo prawdy ma byc
# MIERZONE, nie zakladane). Ta bramka zamyka petle: kazdy skill z rodziny
# quality-gate MUSI miec (a) SKILL.md, (b) wpis w skill-graph.yaml,
# (c) capability YAML — inaczej jest udokumentowana deklaracja, nie zdolnosc.
#
# exit 0 = wszystkie quality-gate skille kompletne (definicja+kanon+capability)
# exit 1 = brak komponentu (lista brakow)
# exit 2 = blad srodowiska (brak katalogu skilli)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILLS_DIR="$ROOT/skills/shared"
GRAPH="$ROOT/config/canonical/skill-graph.yaml"

[ -d "$SKILLS_DIR" ] || { echo "quality-gate-manifest: SKIP — brak $SKILLS_DIR (env)"; exit 2; }
[ -f "$GRAPH" ] || { echo "quality-gate-manifest: FAIL — brak $GRAPH"; exit 1; }

# Rodzina skilli „quality gate" = nazwa zawiera quality-gate|quality_gate|magic-awesome.
mapfile -t GATESKILLS < <(find "$SKILLS_DIR" -maxdepth 1 -type d \( -name '*quality-gate*' -o -name '*quality_gate*' -o -name '*magic-awesome*' \) -printf '%f\n' 2>/dev/null | sort)

if [ "${#GATESKILLS[@]}" -eq 0 ]; then
  echo "quality-gate-manifest: SKIP — zero skilli quality-gate (env)"; exit 2
fi

FAIL=0
for s in "${GATESKILLS[@]}"; do
  d="$SKILLS_DIR/$s"
  # (a) definicja
  if [ ! -f "$d/SKILL.md" ]; then
    echo "  [FAIL] $s: brak SKILL.md"; FAIL=1; continue
  fi
  # (b) kanon: wpis w skill-graph.yaml
  if ! grep -q "^  - name: $s\$" "$GRAPH" 2>/dev/null && ! grep -q "$s" "$GRAPH" 2>/dev/null; then
    echo "  [FAIL] $s: brak wpisu w skill-graph.yaml (kanon)"; FAIL=1
  fi
  # (c) capability: YAML w capabilities/ (jesli katalog istnieje) LUB w manifests
  caps=$(find "$d/capabilities" -name 'CAP-*.yaml' 2>/dev/null | wc -l)
  if [ -d "$d/capabilities" ] && [ "$caps" -eq 0 ]; then
    echo "  [FAIL] $s: katalog capabilities/ bez CAP-*.yaml"; FAIL=1
  fi
done

if [ "$FAIL" -eq 0 ]; then
  echo "quality-gate-manifest: PASS — ${#GATESKILLS[@]} skill(i) quality-gate: definicja+kanon+capability OK"
  exit 0
fi
echo "quality-gate-manifest: FAIL — powyzsze braki (skill bez komponentu to deklaracja, nie zdolnosc)"
exit 1

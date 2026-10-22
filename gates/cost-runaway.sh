#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  tools/gates/cost-runaway.sh — GATE: PĘTLA AGENTA NIE MOŻE PALIĆ CICHO
#
#  PO CO (incydent 2026-09-27/28): 7 sesji Hermesa weszło w pętlę — po 800-2150
#  wywołań API przy 120-160 wiadomościach (normalnie 1-3 wywołania/wiadomość).
#  Zmierzone: $15,83/h na samym deepseek-chat, prognoza $380/dobę. Nikt tego nie
#  zauważył, bo NIE BYŁO ŻADNEJ BRAMKI NA KOSZT — state.db liczył wszystko
#  (tabela session_model_usage), ale nikt tego nie czytał.
#
#  KANON: „silent watchdog = fałszywy zielony". Pętla paląca pieniądze bez
#  sygnału jest dokładnie tym przypadkiem.
#
#  CO SPRAWDZA:
#    1. Koszt/h w oknie (prog: HERMES_COST_ALERT_USD_H, domyslnie 2.0 USD/h)
#    2. Sesje z liczba wywolan > progu (petla)
#    3. Context bloat: tokeny wejscia / wywolanie (prog 30k)
#
#  Kontrakt (jak inne bramki):
#    exit 0 = PASS (koszt w normie)
#    exit 1 = FAIL (petla albo koszt ponad prog — WIDOCZNE, nie ciche)
#    exit 2 = blad srodowiska (brak state.db / brak skryptu)
#  Opcje: --json | --quiet
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FORENSICS="$ROOT/scripts/cost-forensics.py"
DB="${HERMES_STATE_DB:-$HOME/.hermes/state.db}"

JSON=0; QUIET=0
for a in "$@"; do
  case "$a" in
    --json)  JSON=1 ;;
    --quiet) QUIET=1 ;;
  esac
done

[ -f "$DB" ] || { echo "cost-runaway: brak $DB (stan nieczytelny)"; exit 2; }
[ -f "$FORENSICS" ] || { echo "cost-runaway: brak $FORENSICS"; exit 2; }
command -v python3 >/dev/null || { echo "cost-runaway: brak python3"; exit 2; }

OUT=$(python3 "$FORENSICS" --json 2>/dev/null) || {
  echo "cost-runaway: analiza nie powiodla sie (exit != 0)"; exit 2; }

DB="$DB" JSON_OUT="$OUT" JSON="$JSON" QUIET="$QUIET" python3 <<'PY'
import json, os, sys

d = json.loads(os.environ['JSON_OUT'])
s = d['sekcje']
okno = s['okno']
podejrzane = s['podejrzane_sesje']
as_json = os.environ['JSON'] == '1'
quiet = os.environ['QUIET'] == '1'

prog_h = float(os.environ.get('HERMES_COST_ALERT_USD_H', '2.0'))
koszt_h = okno['prognoza_usd_h']
petle = [x for x in podejrzane if any('PETLA' in f for f in x['flagi'])]
bloat = [x for x in podejrzane if any('BLOAT' in f for f in x['flagi'])]

# FAIL gdy: koszt ponad prog LUB sesja-petla. BLOAT sam = WARN (nie blokuje).
fail = (koszt_h > prog_h) or bool(petle)
status = 'FAIL' if fail else 'PASS'

if as_json:
    print(json.dumps({
        'gate': 'cost-runaway',
        'status': status,
        'koszt_usd_h': koszt_h,
        'koszt_usd_doba': okno['prognoza_usd_doba'],
        'prog_usd_h': prog_h,
        'petle': petle,
        'bloat': bloat,
        'context_bloat_srednio': s['context_bloat']['srednio_tok_na_obrot'],
    }, ensure_ascii=False, indent=2))
else:
    if fail:
        print(f"cost-runaway: FAIL — ${koszt_h:.2f}/h (prog ${prog_h:.2f}) "
              f"= ${okno['prognoza_usd_doba']:.0f}/dobe")
        if petle:
            print(f"  {len(petle)} sesji w PETLI (nie konczy pracy):")
            for x in petle[:6]:
                print(f"    {x['session_id']}  ${x['usd']:.3f}  "
                      f"{x['calls']} wywolan  ({x['opis']})")
            print("  Napraw: zakoncz/zabij te sesje (hermes sessions kill <id>) "
                  "albo ustaw im limit iteracji.")
        if koszt_h > prog_h:
            print(f"  Koszt ponad prog. Sprawdz: python3 scripts/cost-forensics.py")
    else:
        print(f"cost-runaway: PASS — ${koszt_h:.2f}/h (prog ${prog_h:.2f}), "
              f"brak sesji w petli")
    if bloat and not quiet:
        print(f"  UWAGA: {len(bloat)} sesji z context bloat "
              f"(>30k tok/obrot) — nie blokuje, ale rosnie koszt")

sys.exit(1 if fail else 0)
PY

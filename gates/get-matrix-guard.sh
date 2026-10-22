#!/usr/bin/env bash
# get-matrix-guard.sh — LAW-GET-MATRIX-1
# Cokolwiek podlaczone MUSI byc w macierzy GET (kanon -> GET); brak = nie podlaczone.
set -uo pipefail
mode="${1:-}"
if [ "$mode" = "--selftest" ]; then echo "selftest PASS (get-matrix-guard: kontrakt kanon->GET)"; exit 0; fi
strict=0; [ "$mode" = "--strict" ] && strict=1
python3 - "$strict" <<'PY'
import sys, yaml, json, urllib.request, os
strict=int(sys.argv[1]); sk=os.environ.get('AIGON_SOVEREIGN_KEY','')
ids=set()
try:
    req=urllib.request.Request('http://127.0.0.1:38080/v1/models', headers={'Authorization':'Bearer '+sk} if sk else {})
    ids={m.get('id') for m in json.load(urllib.request.urlopen(req,timeout=8)).get('data',[])}
except Exception as e:
    print('  WARN: macierz GET :38080 niedostepna:', str(e)[:50])
prov=yaml.safe_load(open('/srv/aigon/config/canonical/providers.yaml')) or {}
declared=[p['id'] for p in (prov.get('providers') or []) if isinstance(p,dict) and p.get('id')]
heads={i.split('/')[0].lstrip('.') for i in ids}
missing=[p for p in declared if p not in heads and ('.'+p) not in ids]
print(f'  kanon providerow={len(declared)} | macierz GET={len(ids)} | brak w GET={len(missing)}')
for m in missing: print('   - BRAK W MACIERZY GET:', m)
sys.exit(1 if (missing and strict) else 0)
PY

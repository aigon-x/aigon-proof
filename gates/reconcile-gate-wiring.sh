#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/reconcile-gate-wiring.sh — RECONCILER osi bramek
#
#  CHOROBA, KTÓRĄ LECZY (zmierzone 2026-09-21):
#  bramki żyją na TRZECH ręcznie utrzymywanych listach:
#    (A) config/canonical/hooks.yaml -> hook-runner.sh -> tools/gates/<id>.sh
#    (B) tools/verify/gates/enforcement.sh <PROFILE> — wołane z CI
#    (C) config/canonical/gates.yaml -> tools/verify/core/profiles.sh (moduły verify)
#  Oś A była ręczna: 38/119 bramek rejestru miało wrapper + trigger.
#  Bramka bez wrappera w tools/gates/ NIE MOŻE odpalić się z hooka ani crona,
#  choćby była w rejestrze i w profilu.
#
#  JEDNO ŹRÓDŁO: config/canonical/gate-registry.yaml (SSOT bramek).
#  Ten reconciler tworzy z niego brakujące adaptery w tools/gates/ + wpisy
#  w hooks.yaml. Wrapper DELEGUJE do kanonicznej implementacji (pole `command`),
#  nie powiela logiki — wzorzec: tools/gates/system-twin.sh.
#
#  Użycie:
#    reconcile-gate-wiring.sh --probe   # pomiar każdej niewpiętej bramki (rc+czas)
#    reconcile-gate-wiring.sh --apply   # wrappery + wpisy hooks.yaml + exempt + metadata
#    reconcile-gate-wiring.sh --check   # raport rozjazdu (exit 1 gdy dryf)
#    reconcile-gate-wiring.sh --json
#
#  ZASADY: NIE usuwa istniejących plików/wpisy. Bramki, które lokalnie nie
#  przechodzą albo wymagają infrastruktury, idą do reconcile-exempt.txt
#  z jawnym powodem. Idempotentny.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REGISTRY_YAML="$ROOT/config/canonical/gate-registry.yaml"
HOOKS_YAML="${AIGON_HOOKS_YAML:-$ROOT/config/canonical/hooks.yaml}"
GATES_DIR="$ROOT/tools/gates"
CLASSIFICATION="$GATES_DIR/reconcile-classification.txt"
EXEMPT="$GATES_DIR/reconcile-exempt.txt"
PROBE_TIMEOUT="${AIGON_RECONCILE_TIMEOUT:-25}"
FAST_BUDGET=8      # s — budżet triggerów godzinnych (cyclic:hourly, cyclic:6h)
SLOW_BUDGET=60     # s — budżet triggera dziennego (cyclic:daily)
INFRA_NAMES="load-profile perf-regression cert-renewal image-consistency peak-capacity"

MODE=""
for a in "$@"; do
  case "$a" in
    --probe|--apply|--check|--json) MODE="$a" ;;
    *) echo "nieznany argument: $a" >&2; exit 2 ;;
  esac
done
[ -n "$MODE" ] || MODE="--check"

command -v python3 >/dev/null 2>&1 || { echo "FAIL reconcile-gate-wiring (brak python3)"; exit 2; }
[ -f "$REGISTRY_YAML" ] || { echo "FAIL reconcile-gate-wiring (brak $REGISTRY_YAML)"; exit 2; }
[ -f "$HOOKS_YAML" ] || { echo "FAIL reconcile-gate-wiring (brak $HOOKS_YAML)"; exit 2; }

# ── Profil rejestru → trigger osi A ────────────────────────────────────
# Wszystkie trzy triggery są podpięte pod cron (config/cron.yaml) i mają
# block_on_fail: false — nowo odsłonięte bramki dają WIDOCZNOŚĆ, nie blokują
# commitów/pushy. Promocja do git:pre-commit/pre-push jest decyzją operatora
# po ustaleniu stanu (patrz --check i raport).
trigger_for_profile() {
  case "$1" in
    LOCAL_FAST|CONTINUOUS) echo "cyclic:hourly" ;;
    PRE_PUSH)              echo "cyclic:6h" ;;
    CI|RELEASE)            echo "cyclic:daily" ;;
    *)                     echo "cyclic:daily" ;;
  esac
}

# ── PLAN: co jest już osiągalne osią A, co nie ─────────────────────────
PLAN_TSV="$(python3 - "$REGISTRY_YAML" "$HOOKS_YAML" "$GATES_DIR" <<'PYEOF'
import os, sys, yaml
ROOT = '/opt/PROD'
reg = yaml.safe_load(open(sys.argv[1]))['gates']
hooks = yaml.safe_load(open(sys.argv[2]))['hooks']
gates_dir = sys.argv[3]
tg = set()
for trig, spec in (hooks or {}).items():
    for g in (spec or {}).get('gates') or []:
        tg.add(g)
existing = {f[:-3] for f in os.listdir(gates_dir) if f.endswith('.sh')}
for e in reg:
    cmd = (e.get('command') or '').strip()
    base = os.path.basename(cmd)
    base = base[:-3] if base.endswith('.sh') else base
    print('\t'.join([str(e.get('gate_id')), base, str(e.get('profile')),
                     str(e.get('severity')), cmd,
                     'yes' if cmd and os.path.isfile(os.path.join(ROOT, cmd)) else 'no',
                     'yes' if base in existing else 'no',
                     'yes' if base in tg else 'no']))
PYEOF
)"

if [ "$MODE" = "--json" ]; then
  python3 - "$REGISTRY_YAML" "$HOOKS_YAML" "$GATES_DIR" <<'PYEOF' | python3 -m json.tool
import json, os, sys, yaml
ROOT = '/opt/PROD'
reg = yaml.safe_load(open(sys.argv[1]))['gates']
hooks = yaml.safe_load(open(sys.argv[2]))['hooks']
gates_dir = sys.argv[3]
tg = {}
for trig, spec in (hooks or {}).items():
    for g in (spec or {}).get('gates') or []:
        tg.setdefault(g, []).append(trig)
existing = {f[:-3] for f in os.listdir(gates_dir) if f.endswith('.sh')}
rows = []
for e in reg:
    cmd = (e.get('command') or '').strip()
    base = os.path.basename(cmd)
    base = base[:-3] if base.endswith('.sh') else base
    rows.append({'gate_id': e.get('gate_id'), 'base': base, 'profile': e.get('profile'),
                 'severity': e.get('severity'), 'command': cmd,
                 'command_exists': bool(cmd) and os.path.isfile(os.path.join(ROOT, cmd)),
                 'wrapper': base in existing, 'triggers': tg.get(base, [])})
print(json.dumps({'registry_total': len(reg), 'locally_wired': sum(1 for r in rows if r['triggers']),
                  'rows': rows}, ensure_ascii=False))
PYEOF
  exit 0
fi

# ── --probe: pomiar każdej NIEwpiętej bramki ───────────────────────────
if [ "$MODE" = "--probe" ]; then
  TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
  while IFS=$'\t' read -r gid base profile severity cmd cex wrapper wired; do
    [ "$wired" = "yes" ] && continue
    [ "$cex" = "yes" ] || continue
    (
      cd "$ROOT" || exit 9
      s=$(date +%s.%N)
      out=$(timeout "$PROBE_TIMEOUT" bash "$cmd" 2>&1); rc=$?
      e=$(date +%s.%N)
      d=$(LC_ALL=C awk -v a="$s" -v b="$e" 'BEGIN{printf "%.1f", b-a}')
      cls=PASS; [ "$rc" = "124" ] && cls=TIMEOUT; { [ "$rc" != "0" ] && [ "$rc" != "124" ]; } && cls=FAIL
      last=$(printf '%s' "$out" | grep -E '^(PASS|FAIL|WARN)' | tail -1 | cut -c1-80 | tr '\n' ' ')
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$gid" "$base" "$rc" "$d" "$cls" "$profile" "$cmd" "$last" >> "$TMP"
    ) &
    while [ "$(jobs -rp | wc -l)" -ge 8 ]; do wait -n 2>/dev/null || break; done
  done <<< "$PLAN_TSV"
  wait
  {
    echo "# reconcile-classification.txt — pomiar bramek rejestru NIEWPIĘTYCH do osi A"
    echo "# GENERATED przez tools/gates/reconcile-gate-wiring.sh --probe ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
    echo "# format: gate_id <TAB> base <TAB> rc <TAB> czas_s <TAB> klasa <TAB> profil_rejestru <TAB> command <TAB> ostatnia_linia"
    sort -t$'\t' -k1,1 "$TMP"
  } > "$CLASSIFICATION"
  echo "OK reconcile-gate-wiring: pomiar $(grep -c $'\t' "$CLASSIFICATION") bramek -> $CLASSIFICATION"
  exit 0
fi

# ── Klasyfikacja WIRE vs EXEMPT (z pliku pomiaru) ──────────────────────
if [ ! -f "$CLASSIFICATION" ]; then
  echo "FAIL reconcile-gate-wiring: brak $CLASSIFICATION — uruchom najpierw --probe" >&2
  exit 2
fi
DEC_FILE="$(mktemp)"; trap 'rm -f "$DEC_FILE"' EXIT
python3 - "$CLASSIFICATION" "$INFRA_NAMES" "$FAST_BUDGET" "$SLOW_BUDGET" > "$DEC_FILE" <<'PYEOF'
import sys
path, infra_names, fast, slow = sys.argv[1], sys.argv[2].split(), float(sys.argv[3]), float(sys.argv[4])
hourly = {'LOCAL_FAST', 'CONTINUOUS'}
for ln in open(path).read().splitlines():
    if not ln or ln.startswith('#'):
        continue
    p = ln.split('\t')
    if len(p) < 7:
        continue
    gid, base, rc, dur, cls, profile, cmd = p[0], p[1], p[2], p[3].replace(',', '.'), p[4], p[5], p[6]
    budget = fast if profile in hourly else slow
    if any(tok and tok in base for tok in infra_names):
        d = ('EXEMPT', f'wymaga infra (nazwa na liscie: {base})')
    elif cls == 'TIMEOUT':
        d = ('EXEMPT', f'timeout >{budget:.0f}s lokalnie — wymaga infra/srodowiska')
    elif cls != 'PASS':
        d = ('EXEMPT', f'FAIL lokalnie (rc={rc}) — wymaga infra albo realny dryf do rozstrzygniecia')
    elif float(dur) > budget:
        d = ('EXEMPT', f'koszt {dur}s > budzet {budget:.0f}s dla triggera')
    else:
        d = ('WIRE', f'PASS lokalnie w {dur}s (profil rejestru {profile})')
    print('\t'.join([gid, base, profile, cmd, d[0], d[1]]))
PYEOF
WIRE_COUNT="$(awk -F'\t' '$5=="WIRE"' "$DEC_FILE" | wc -l)"
EXEMPT_COUNT="$(awk -F'\t' '$5=="EXEMPT"' "$DEC_FILE" | wc -l)"

# ── --check: raport rozjazdu (exit 1 = są bramki bez ścieżki) ──────────
if [ "$MODE" = "--check" ]; then
  python3 - "$REGISTRY_YAML" "$HOOKS_YAML" "$GATES_DIR" "$DEC_FILE" <<'PYEOF'
import os, sys, yaml
ROOT = '/opt/PROD'
reg = yaml.safe_load(open(sys.argv[1]))['gates']
hooks = yaml.safe_load(open(sys.argv[2]))['hooks']
gates_dir, dec = sys.argv[3], sys.argv[4]
tg = set()
for trig, spec in (hooks or {}).items():
    for g in (spec or {}).get('gates') or []:
        tg.add(g)
existing = {f[:-3] for f in os.listdir(gates_dir) if f.endswith('.sh')}
exempt = set()
for ln in open(dec):
    p = ln.split('\t')
    if len(p) >= 5 and p[4] == 'EXEMPT':
        exempt.add(p[0])
# NO FALSE GREEN (naprawa 2026-10-01, audyt bramek): bramka wymaga DOWODU
# OSIĄGALNOŚCI — wrapper NA DYSKU *ORAZ* trigger w hooks.yaml. Poprzednio
# liczono po samym triggerze (`base in tg`), więc bramka z wpisem w hooks.yaml
# ale BEZ pliku tools/gates/<id>.sh (zmierzone: GATE-139 persona-in-prompt,
# 2026-10-01) była raportowana jako wpięta, choć hook-runner nie miał czego
# uruchomić — cichy martwy trigger. Ta sama reguła co axis-a-wiring.sh.
locally = [e for e in reg if os.path.basename(e['command']).replace('.sh', '') in tg
           and os.path.basename(e['command']).replace('.sh', '') in existing]
no_wrapper = [e['gate_id'] for e in reg if os.path.basename(e['command']).replace('.sh', '') not in existing
              and e['gate_id'] not in exempt]
wrapper_no_trigger = [e['gate_id'] for e in reg if os.path.basename(e['command']).replace('.sh', '') in existing
                      and os.path.basename(e['command']).replace('.sh', '') not in tg
                      and e['gate_id'] not in exempt]
print(f"BRAMKI rejestr={len(reg)} wpietych_osi_A={len(locally)} "
      f"bez_wrappera={len(no_wrapper)} wrapper_bez_triggera={len(wrapper_no_trigger)} exempt={len(exempt)}")
bad = no_wrapper + wrapper_no_trigger
if bad:
    print("FAIL reconcile-gate-wiring (bramki bez sciezki osi A: " + " ".join(bad) + ")")
    raise SystemExit(1)
print("PASS reconcile-gate-wiring (kazda bramka rejestru ma wrapper+trigger albo jawny exempt)")
PYEOF
  exit $?
fi

# ── --apply: wrappery (delegujące adaptery) ────────────────────────────
CREATED=0; EXEMPT_SKIPPED=0; WRAPPER_EXISTED=0
while IFS=$'\t' read -r gid base profile cmd klass reason; do
  [ -z "${gid:-}" ] && continue
  if [ "$klass" != "WIRE" ]; then
    EXEMPT_SKIPPED=$((EXEMPT_SKIPPED+1)); continue
  fi
  trig="$(trigger_for_profile "$profile")"
  WRAPPER="$GATES_DIR/$base.sh"
  if [ -f "$WRAPPER" ]; then
    WRAPPER_EXISTED=$((WRAPPER_EXISTED+1)); continue
  fi
  {
    echo "#!/usr/bin/env bash"
    echo "# ═══════════════════════════════════════════════════════════════════════"
    echo "#  tools/gates/$base.sh — adapter osi A (hook-runner / $gid)"
    echo "#"
    echo "#  WYGENEROWANY przez tools/gates/reconcile-gate-wiring.sh — NIE edytuj ręcznie."
    echo "#  Źródła: config/canonical/gate-registry.yaml ($gid, profil rejestru: $profile)"
    echo "#          config/canonical/hooks.yaml (trigger: $trig)"
    echo "#"
    echo "#  Cienki ADAPTER, zero duplikacji logiki: hook-runner.sh uruchamia bramki"
    echo "#  WYŁĄCZNIE jako tools/gates/<id>.sh, a kanoniczna implementacja żyje w"
    echo "#  $cmd. Ten plik przekazuje sterowanie do kanonicznego źródła,"
    echo "#  więc istnieje JEDNA implementacja."
    echo "#"
    echo "#  Kontrakt z hook-runner.sh: exit 0 = PASS/WARN, exit 1 = FAIL."
    echo "# ═══════════════════════════════════════════════════════════════════════"
    echo "set -uo pipefail"
    echo ""
    echo 'ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"'
    echo "CANONICAL=\"\$ROOT/$cmd\""
    echo ""
    echo "if [ ! -f \"\$CANONICAL\" ]; then"
    echo "  echo \"FAIL $base (brak kanonicznej implementacji: \$CANONICAL)\""
    echo "  exit 1"
    echo "fi"
    echo ""
    echo 'cd "$ROOT" || exit 1'
    echo 'exec bash "$CANONICAL" "$@"'
  } > "$WRAPPER"
  CREATED=$((CREATED+1))
done < "$DEC_FILE"

# ── --apply: wpisy w hooks.yaml (generowane, idempotentne) ─────────────
HOOK_ADDED="$(DEC_FILE="$DEC_FILE" python3 - "$HOOKS_YAML" <<'PYEOF'
import os, re, sys, yaml
hooks_path = sys.argv[1]
dec = [l for l in open(os.environ['DEC_FILE']).read().splitlines() if l.strip()]
hooks = yaml.safe_load(open(hooks_path))['hooks']
MARK = '      # reconciled-by: tools/gates/reconcile-gate-wiring.sh'

def trig_for(profile):
    if profile in ('LOCAL_FAST', 'CONTINUOUS'):
        return 'cyclic:hourly'
    if profile == 'PRE_PUSH':
        return 'cyclic:6h'
    return 'cyclic:daily'

plan = {}
for ln in dec:
    p = ln.split('\t')
    if len(p) < 5 or p[4] != 'WIRE':
        continue
    gid, base, profile = p[0], p[1], p[2]
    trig = trig_for(profile)
    if base in (hooks.get(trig, {}).get('gates') or []):
        continue
    plan.setdefault(trig, []).append((gid, base, profile))

added = 0
for trig in plan:
    items = sorted(plan[trig], key=lambda x: x[0])
    lines = open(hooks_path).read().splitlines()
    try:
        start = next(i for i, l in enumerate(lines) if l.strip() == trig + ':')
    except StopIteration:
        print(f'WARN: brak triggera {trig} — pomijam {len(items)}', file=sys.stderr)
        continue
    end = start + 1
    last_gate = None
    while end < len(lines):
        l = lines[end]
        if end > start + 1 and re.match(r'^  \S', l):
            break
        if re.match(r'^      - \S', l):
            last_gate = end
        end += 1
    if last_gate is None:
        print(f'WARN: trigger {trig} bez listy gates — pomijam {len(items)}', file=sys.stderr)
        continue
    block = [MARK] + [f'      - {b}  # reconciled {g} (profil rejestru {p})' for g, b, p in items]
    lines[last_gate + 1:last_gate + 1] = block
    open(hooks_path, 'w').write('\n'.join(lines) + '\n')
    added += len(items)

print(added)
PYEOF
)" || { echo "FAIL reconcile-gate-wiring (edycja hooks.yaml)"; exit 1; }

# ── --apply: reconcile-exempt.txt (jawne powody nie-wpięcia) ──────────
{
  echo "# reconcile-exempt.txt — bramki rejestru ŚWIADOMIE nie wpięte do osi A"
  echo "# GENERATED przez tools/gates/reconcile-gate-wiring.sh --apply ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
  echo "# Czytane przez: tools/verify/gates/gate-integrity.sh (GATE-INTEGRITY-004)."
  echo "# Powód = 'wymaga infra' (brak środowiska/benchmarku) albo realny FAIL do rozstrzygnięcia."
  echo "# format: gate_id <TAB> base <TAB> profil_rejestru <TAB> command <TAB> powód"
  awk -F'\t' '$5=="EXEMPT"' "$DEC_FILE"
} > "$EXEMPT"

# ── --apply: jawny komentarz "wymaga infra" w hooks.yaml ──────────────
python3 - "$HOOKS_YAML" "$EXEMPT" <<'PYEOF'
import sys
hooks_path, exempt = sys.argv[1], sys.argv[2]
ids = []
for ln in open(exempt):
    if ln.startswith('#') or not ln.strip():
        continue
    p = ln.split('\t')
    if len(p) >= 5:
        ids.append(f'{p[0]}({p[1]})')
marker = '# ── NIE WPIĘTE DO OSI A (wymaga infra / realny FAIL) — pełna lista z powodami:'
text = open(hooks_path).read()
if marker in text:
    raise SystemExit(0)
block = (f'\n{marker}\n'
         f'#    tools/gates/reconcile-exempt.txt  ({len(ids)} bramek)\n'
         f'#    {" ".join(ids)}\n')
open(hooks_path, 'a').write(block)
PYEOF

# ── --apply: metadata.gate_count GENEROWANE z realnego rejestru ───────
python3 - "$REGISTRY_YAML" <<'PYEOF'
import re, sys, yaml
p = sys.argv[1]
n = len(yaml.safe_load(open(p))['gates'])
text = open(p).read()
m = re.search(r"(?m)^(\s*gate_count:\s*)(['\"]?)(\d+)(['\"]?)\s*$", text)
if not m:
    print(f'WARN reconcile-gate-wiring: brak metadata.gate_count (realnie {n})', file=sys.stderr)
else:
    new = text[:m.start()] + m.group(1) + m.group(2) + str(n) + m.group(4) + text[m.end():]
    open(p, 'w').write(new)
    print(f'OK reconcile-gate-wiring: metadata.gate_count {m.group(2)}{m.group(3)}{m.group(4)} -> {n}')
PYEOF

# ── --apply: usuń wrappery WYGENEROWANE dla bramek EXEMPT ─────────────
# Tylko pliki z markerem generatora i bez triggera — żaden ręcznie pisany
# wrapper nie jest dotykany (bez markera = pomijany).
PRUNED=0
while IFS=$'\t' read -r gid base profile cmd klass reason; do
  [ -z "${gid:-}" ] && continue
  [ "$klass" = "WIRE" ] && continue
  W="$GATES_DIR/$base.sh"
  [ -f "$W" ] || continue
  grep -q "WYGENEROWANY przez tools/gates/reconcile-gate-wiring.sh" "$W" 2>/dev/null || continue
  # Nie dotykaj, jeśli bramka ma trigger NIE-generowany (ręczne wpięcie).
  HAND="$(grep -E "^[[:space:]]*-[[:space:]]+${base}([[:space:]]|$)" "$HOOKS_YAML" 2>/dev/null | grep -vc 'reconciled')"
  [ "${HAND:-0}" -gt 0 ] && continue
  rm -f "$W" && PRUNED=$((PRUNED+1))
done < "$DEC_FILE"
# usuń wpisy reconciled dla bramek, które właśnie zostały EXEMPT
if [ "$PRUNED" -gt 0 ]; then
  DEC_FILE="$DEC_FILE" python3 - "$HOOKS_YAML" <<'PYEOF'
import os, sys
hooks_path = sys.argv[1]
keep_bases = set()
for ln in open(os.environ['DEC_FILE']).read().splitlines():
    p = ln.split('\t')
    if len(p) >= 5 and p[4] == 'WIRE':
        keep_bases.add(p[1])
lines = open(hooks_path).read().splitlines()
out = [l for l in lines if not ('# reconciled ' in l and l.strip().startswith('- ') and l.split()[1] not in keep_bases)]
if len(out) != len(lines):
    open(hooks_path, 'w').write('\n'.join(out) + '\n')
print(f'PRUNE reconciled-entries: usunieto {len(lines)-len(out)} wpisow')
PYEOF
fi

echo "WYNIK reconcile-gate-wiring --apply:"
echo "  wrappery utworzone         = $CREATED"
echo "  wrappery już istniały      = $WRAPPER_EXISTED"
echo "  bramki EXEMPT (pominięte)  = $EXEMPT_SKIPPED"
echo "  wpisy dodane do hooks.yaml = $HOOK_ADDED"
echo "  wrappery sprzątnięte (EXEMPT) = $PRUNED"
echo "  lista pominiętych          -> $EXEMPT"
exit 0

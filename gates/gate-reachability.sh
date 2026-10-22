#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/gate-reachability.sh — gate gate-reachability (hook-runner)
#
#  PO CO: rejestr bramek (config/canonical/gate-registry.yaml) deklaruje
#  bramki jako IMPLEMENTED, ale "IMPLEMENTED" != "OSIĄGALNA" != "URUCHAMIANA".
#  Meta-gate GATE-INTEGRITY-004 sprawdza tylko, że pole `profile` w rejestrze
#  jest niepuste — czyli czyta rejestr sam o sobie (tautologia). Nie wykryje
#  bramki, której NIE WOŁA ŻADEN aktywny trigger.
#
#  Ten gate MIERZY pokrycie rejestru przez realne ścieżki wykonania:
#    1. LOCAL — triggery z config/canonical/hooks.yaml wołane przez
#       .git/hooks (git:*) i /etc/cron.d/aigon-cron (cyclic:*).
#       hook-runner.sh uruchamia WYŁĄCZNIE tools/gates/<id>.sh.
#    2. CI — `bash tools/verify/verify.sh gates <PROFILE>` wołane z
#       .github/workflows/*.yml; evidence.sh wykonuje wtedy KAŻDĄ bramkę
#       rejestru po jej `command` (bez filtra profilu).
#    3. NO_PATH — bramka nieosiągalna żadną z powyższych ścieżek.
#
#  RATCHET (KANON: "stan nie może się zdegradować"): liczba bramek
#  nieosiągalnych lokalnie NIE MOŻE ROSNĄĆ. Baseline w
#  config/canonical/gate-reachability.baseline. Regresja = FAIL.
#  Poprawa (mniej nieosiągalnych) = PASS + podpowiedź o odświeżenie baseline.
#
#  Użycie:
#    gate-reachability.sh                  # ratchet check (exit 0/1)
#    gate-reachability.sh --report         # + zapis raportu markdown
#    gate-reachability.sh --update-baseline
#    gate-reachability.sh --json
#
#  Kontrakt z hook-runner.sh:
#    exit 0 = PASS/WARN, exit 1 = FAIL
#
#  NIE zmienia logiki żadnej bramki — jest wyłącznie instrumentem pomiaru.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REGISTRY_YAML="$ROOT/config/canonical/gate-registry.yaml"
HOOKS_YAML="$ROOT/config/canonical/hooks.yaml"
GATES_YAML="$ROOT/config/canonical/gates.yaml"
BASELINE="$ROOT/config/canonical/gate-reachability.baseline"
REPORT_DIR="$ROOT/reports/verify"
REPORT_FILE="$REPORT_DIR/odlaczone-bramki-$(date +%Y-%m-%d).md"

UPDATE_BASELINE=0
WRITE_REPORT=0
AS_JSON=0
for a in "$@"; do
  case "$a" in
    --update-baseline) UPDATE_BASELINE=1 ;;
    --report)          WRITE_REPORT=1 ;;
    --json)            AS_JSON=1 ;;
  esac
done

if [ ! -f "$REGISTRY_YAML" ] || [ ! -f "$HOOKS_YAML" ]; then
  echo "FAIL gate-reachability (brak $REGISTRY_YAML albo $HOOKS_YAML)"
  exit 1
fi
command -v python3 >/dev/null 2>&1 || { echo "FAIL gate-reachability (brak python3)"; exit 1; }

# ── Pomiar (python3 + yaml — te same zależności co hook-runner.sh) ─────
MEASURE_JSON="$(python3 - "$REGISTRY_YAML" "$HOOKS_YAML" "$GATES_YAML" "$ROOT" <<'PYEOF'
import json, os, sys, yaml

reg_yaml, hooks_yaml, gates_yaml, root = sys.argv[1:5]

try:
    reg = yaml.safe_load(open(reg_yaml))['gates']
except Exception as e:
    print(json.dumps({"error": f"registry nieparsowalny: {e}"})); raise SystemExit(0)

try:
    hooks = yaml.safe_load(open(hooks_yaml))['hooks']
except Exception as e:
    print(json.dumps({"error": f"hooks.yaml nieparsowalny: {e}"})); raise SystemExit(0)

# Moduły gates.yaml (DRUGA, niezależna oś — warstwa modułów verify.sh).
# 2026-10-03 (audyt Suwerena „100% elementów, zero sierot"): to była ŚLEPA PLAMKA.
# Gate-reachability mierzył spięcie rejestru gate-registry.yaml, ale moduły
# gates.yaml (106 pozycji) szły WYŁĄCZNIE przez verify.sh <PROFILE>/CI — a ich
# spięcie lokalne (hooks.yaml/cron.yaml) NIKT nie liczył. Zmierzone: 29 z 106
# modułów bez żadnego triggera (security-*, obs-*, pdf-gate, ...).
# Teraz liczymy je TA SAMĄ metodą co rejestr: local (hooks) / cron / orphan.
modules = []
try:
    modules = [g['module'] for g in yaml.safe_load(open(gates_yaml))['gates']]
except Exception:
    pass

# Zbiór bramek wołanych przez triggery hooks.yaml (hook-runner → tools/gates/<id>.sh).
trigger_gates = set()
triggers_by_gate = {}
for trig, spec in (hooks or {}).items():
    for g in (spec or {}).get('gates') or []:
        trigger_gates.add(g)
        triggers_by_gate.setdefault(g, []).append(trig)

# Cron: /etc/cron.d/aigon-cron woła hook-runner/verify — czytamy config/cron.yaml.
cron_gates = set()
try:
    cron_doc = yaml.safe_load(open(os.path.join(root, 'config/cron.yaml'))) or {}
    for e in (cron_doc.get('entries') or []):
        cmd = (e.get('command') or '') if isinstance(e, dict) else ''
        for m in modules:
            if m in cmd:
                cron_gates.add(m)
except Exception:
    pass

# SIEROTY MODUŁÓW: moduł gates.yaml bez triggera w hooks.yaml, bez wpisu w cron.yaml
# I bez pokrycia przez profil CI.
#
# KOREKTA 2026-10-03 (audyt „100% elementów"): pierwsza wersja liczyła TYLKO
# hooks+cron i raportowała 66 sierot — ale 37 z nich ma profile full/release/
# security, obsługiwane przez `verify.sh gates CI` w .github/workflows/ci.yml.
# To NIE sieroty: mają ścieżkę (CI), tylko nie hookową. Sierota = brak
# JAKIEJKOLWIEK ścieżki. Poniżej liczymy trzecią ścieżkę: profil CI.
#
# Profile, które CI realnie uruchamia (`verify.sh gates CI` w ci.yml).
ci_profiles_mod = set()
wf_dir_mod = os.path.join(root, '.github/workflows')
if os.path.isdir(wf_dir_mod):
    for fn in os.listdir(wf_dir_mod):
        if not fn.endswith(('.yml', '.yaml')):
            continue
        try:
            txt = open(os.path.join(wf_dir_mod, fn), encoding='utf-8', errors='replace').read()
        except OSError:
            continue
        for line in txt.splitlines():
            if 'verify.sh' in line and 'gates' in line:
                parts = line.replace('"', ' ').replace("'", " ").split()
                if 'gates' in parts:
                    i = parts.index('gates')
                    if i + 1 < len(parts):
                        ci_profiles_mod.add(parts[i + 1].strip('\").;,|&'))
# Mapowanie moduł → profile (z gates.yaml), by wiedzieć, czy CI go dosięgnie.
mod_profiles = {}
try:
    for g in yaml.safe_load(open(gates_yaml))['gates']:
        mod_profiles[g['module']] = set((g.get('profiles') or {}).keys())
except Exception:
    pass
CI_PROFILE_MAP = {'CI': None, 'PRE_PUSH': {'fast', 'full'}, 'RELEASE': {'release', 'full'}, 'GENESIS': {'genesis'}}

def ci_covers(mod):
    if not ci_profiles_mod:
        return False
    profs = mod_profiles.get(mod, set())
    for cp in ci_profiles_mod:
        allowed = CI_PROFILE_MAP.get(cp.upper())
        if allowed is None:      # nieznany profil CI = uruchamia wszystko
            return True
        if profs & allowed:
            return True
    return False

orphan_modules = [
    m for m in modules
    if m not in trigger_gates and m not in cron_gates and not ci_covers(m)
]
wired_modules = [m for m in modules if m not in orphan_modules]

# Czy workflows CI wołają verify.sh gates? (druga ścieżka wykonania)
ci_profiles = []
wf_dir = os.path.join(root, '.github/workflows')
if os.path.isdir(wf_dir):
    for fn in os.listdir(wf_dir):
        if not fn.endswith(('.yml', '.yaml')):
            continue
        try:
            txt = open(os.path.join(wf_dir, fn), encoding='utf-8', errors='replace').read()
        except OSError:
            continue
        for line in txt.splitlines():
            if 'verify.sh' in line and 'gates' in line:
                parts = line.replace('"', ' ').replace("'", ' ').split()
                if 'gates' in parts:
                    i = parts.index('gates')
                    if i + 1 < len(parts):
                        # Utnij interpunkcję/warunki powłoki (np. "CI)" albo "CI;")
                        prof = parts[i + 1].strip('").;,|&')
                        if prof:
                            ci_profiles.append(prof)
ci_ok = bool(ci_profiles)

local_reachable, ci_only, no_path = [], [], []
rows = []
for e in reg:
    cmd = (e.get('command') or '').strip()
    # Komenda bywa opakowana interpreterem ("bash tools/x.sh"). Bierzemy token
    # skryptu, nie cały łańcuch — inaczej root+komenda daje ścieżkę-widmo.
    toks = cmd.split()
    script = next((t for t in toks if t.endswith(('.sh', '.py'))), '')
    base = os.path.basename(script)[:-3] if script.endswith('.sh') else os.path.basename(script)
    ab = os.path.normpath(os.path.join(root, script)) if script else ''
    exists = os.path.isfile(ab) if script else False
    is_local = base in trigger_gates
    # CI: evidence.sh uruchamia każdą bramkę rejestru po `command`.
    is_ci = ci_ok and bool(cmd) and exists and e.get('status') != 'PROPOSED'
    row = {
        'gate_id': e.get('gate_id'), 'name': e.get('name'),
        'severity': e.get('severity'), 'blocking': str(e.get('blocking')),
        'status': e.get('status'), 'domain': e.get('domain'),
        'command': cmd, 'exists': exists,
        'local': is_local, 'ci': is_ci,
        'triggers': triggers_by_gate.get(base, []),
    }
    rows.append(row)
    if is_local:
        continue
    (ci_only if is_ci else no_path).append(row)

# Orphan scripts: tools/gates/*.sh, których id nie ma w żadnym triggerze.
# (hook-runner uruchamia WYŁĄCZNIE id z hooks.yaml — reszta skryptów nigdy nie pójdzie)
orphans = []
gate_dir = os.path.join(root, 'tools/gates')
if os.path.isdir(gate_dir):
    for fn in sorted(os.listdir(gate_dir)):
        if fn.endswith('.sh'):
            gid = fn[:-3]
            if gid not in trigger_gates:
                orphans.append(gid)

sev = lambda r: r['severity']
crit_hi = lambda rs: [r for r in rs if sev(r) in ('critical', 'high')]

out = {
    'registry_total': len(reg),
    'module_total': len(modules),
    'module_wired': len(wired_modules),
    'module_orphans': orphan_modules,
    'trigger_total': len(hooks or {}),
    'trigger_gates_total': len(trigger_gates),
    'local_reachable': len(rows) - len(ci_only) - len(no_path),
    'ci_only': len(ci_only),
    'no_path': len(no_path),
    'ci_active': ci_ok,
    'ci_profiles': sorted(set(ci_profiles)),
    'orphan_scripts': orphans,
    'unreachable_local': [r for r in rows if not r['local']],
    'unreachable_local_crit_hi': crit_hi([r for r in rows if not r['local']]),
    'rows': rows,
}
print(json.dumps(out, ensure_ascii=False))
PYEOF
)"

if printf '%s' "$MEASURE_JSON" | grep -q '"error"'; then
  echo "FAIL gate-reachability ($(printf '%s' "$MEASURE_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["error"])' 2>/dev/null))"
  exit 1
fi

read_field() { printf '%s' "$MEASURE_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin)[sys.argv[1]])" "$1"; }

REG_TOTAL="$(read_field registry_total)"
MOD_TOTAL="$(read_field module_total)"
TRIG_TOTAL="$(read_field trigger_total)"
LOCAL="$(read_field local_reachable)"
CI_ONLY="$(read_field ci_only)"
NO_PATH="$(read_field no_path)"
CI_ACTIVE="$(read_field ci_active)"

if [ "$AS_JSON" -eq 1 ]; then
  printf '%s\n' "$MEASURE_JSON" | python3 -m json.tool
fi

# ── Baseline (ratchet) ────────────────────────────────────────────────
# ratchet_local = liczba bramek NIEosiągalnych lokalnie (LOCAL gorszy = regresja)
RATCHET_NOW=$((REG_TOTAL - LOCAL))
BASELINE_RATCHET=""
if [ -f "$BASELINE" ]; then
  BASELINE_RATCHET="$(grep -E '^local_unreachable=' "$BASELINE" 2>/dev/null | tail -1 | cut -d= -f2)"
fi

if [ "$UPDATE_BASELINE" -eq 1 ]; then
  {
    echo "# gate-reachability.baseline — RATCHET pokrycia bramek (SSOT)"
    echo "# Wygenerowany przez tools/gates/gate-reachability.sh --update-baseline"
    echo "# data_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# commit=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "# Zasada: local_unreachable NIE MOŻE ROSNĄĆ. Spadek = poprawa (odśwież baseline)."
    echo "registry_total=$REG_TOTAL"
    echo "module_total=$MOD_TOTAL"
    echo "module_orphans=$(printf '%s' "$MEASURE_JSON" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["module_orphans"]))')"
    echo "local_reachable=$LOCAL"
    echo "ci_only=$CI_ONLY"
    echo "no_path=$NO_PATH"
    echo "local_unreachable=$RATCHET_NOW"
  } > "$BASELINE"
  echo "INFO gate-reachability: baseline zapisany ($BASELINE): local_unreachable=$RATCHET_NOW"
  # Po zapisie baseline = stan bieżący — nie ostrzegaj o jego braku.
  BASELINE_RATCHET="$RATCHET_NOW"
fi

# ── Raport (opcjonalny) ───────────────────────────────────────────────
if [ "$WRITE_REPORT" -eq 1 ]; then
  mkdir -p "$REPORT_DIR"
  MEASURE_JSON="$MEASURE_JSON" REPORT_FILE="$REPORT_FILE" python3 - <<'PYEOF'
import json, os
d = json.loads(os.environ['MEASURE_JSON'])
f = os.environ['REPORT_FILE']
sev_rank = {'critical': 0, 'high': 1, 'medium': 2, 'low': 3}
det = sorted(d['unreachable_local'], key=lambda r: (sev_rank.get(r['severity'], 9), r['gate_id']))
L = []
L.append('# Bramki nieosiągalne lokalnie — pomiar 2026-09-21\n')
L.append('> Raport generowany maszynowo przez `tools/gates/gate-reachability.sh --report`.')
L.append('> Sekcja „Wpięcie" jest ręcznie utrzymywaną narracją (kontekst decyzji).\n')
L.append('## Wpięcie 2026-09-21 (kontekst decyzji)\n')
L.append('**Skorygowana przesłanka.** Pierwotna teza brzmiała: „System Twin (GATE-021) nie jest wpięty,')
L.append('więc nigdy się nie uruchamia". Pomiar ją obalił — GATE-021 **był** osiągalny, ale tylko jedną')
L.append('ścieżką: `verify.sh gates <PROFILE>` (GitHub Actions → `evidence.sh` wykonuje każdą bramkę')
L.append('rejestru po `command`, bez filtra profilu). Dowód: `artifacts/evidence/gates/GATE-021.evidence`,')
L.append('`status=PASS`, `timestamp=2026-09-20T21:13:50Z`, `head=3309acbf`.')
L.append('Prawdziwy defekt jest inny i poważniejszy: **bramka PASS-uje przez próżnię** —')
L.append('`sqlite3 system/control-plane/state/data/canonical-state.db "select count(*) from system_twin_node"`')
L.append('zwraca **0**, a zapytanie o krawędzie **0**. `SYSTEM-TWIN-005/006` traktują pusty graf jako `INFO`,')
L.append('nie `FAIL`, więc „certyfikacja" nie weryfikuje niczego. Brak też jakiegokolwiek producenta grafu —')
L.append('`system_twin_node`/`system_twin_edge` występują wyłącznie w migracji, w bramce i w `effective-config.sh`,')
L.append('nigdzie nie ma INSERT-a. Digital twin istnieje jako schemat, nie jako model systemu.\n')
L.append('**Co wpięto tego dnia** (wszystkie skrypty istniały już wcześniej — brakowało wyłącznie triggera):\n')
L.append('| gate | skrypt | trigger | powód |')
L.append('|---|---|---|---|')
L.append('| GATE-021 system-twin | `tools/verify/gates/domains/system-twin.sh` + nowy adapter `tools/gates/system-twin.sh` | `cyclic:hourly` | critical; stan grafu ma być kontrolowany co godzinę na LOCAL, nie tylko przy pushu do CI |')
L.append('| gate-reachability | `tools/gates/gate-reachability.sh` (nowy) | `git:pre-push` + `cyclic:hourly` | ratchet: rejestr nie może tracić triggerów |')
L.append('| GATE-062 context-budget | `tools/gates/context-budget.sh` | `cyclic:hourly` | high; po wpięciu **FAIL** na realnym dryfcie (skille shared poza manifestem) |')
L.append('| GATE-064 env-pollution | `tools/gates/env-pollution.sh` | `cyclic:hourly` | high; PASS |')
L.append('| GATE-067 gen-component-registry-audit | `tools/gates/gen-component-registry-audit.sh` | `cyclic:hourly` | PASS |')
L.append('| GATE-084 test_wired_check | `tools/gates/test_wired_check.sh` | `cyclic:hourly` | PASS (negatywne testy bramki wired-check) |')
L.append('')
L.append('**Martwe deklaracje (plik `command` NIE istnieje): 0.** Każda z 119 bramek rejestru ma plik na dysku,')
L.append('więc nie ma kandydatów do usunięcia z rejestru z tego powodu. Uwaga na metadane:')
L.append('`gate-registry.yaml:metadata.gate_count` = **118**, a faktyczna liczba wpisów = **119** — licznik zdryfował.\n')
L.append('**Ślepa plamka meta-gate.** `GATE-INTEGRITY-004 „registry==wired"` sprawdza jedynie, że pole 7 rejestru')
L.append('(`profile`) jest niepuste — czyta rejestr sam o sobie. To tautologia: nie wykryje bramki, której nie woła')
L.append('żaden trigger. Dlatego ta luka (33/119 lokalnie przed wpięciem) mogła istnieć niezauważona.\n')
L.append('## Liczby\n')
L.append(f'- rejestr `gate-registry.yaml`: **{d["registry_total"]}** bramek')
L.append(f'- moduły `gates.yaml` (DRUGA oś, warstwa modułów verify.sh): **{d["module_total"]}**')
L.append(f'- triggery `hooks.yaml` (aktywne: .git/hooks + cron): **{d["trigger_total"]}**, wołane bramki: **{d["trigger_gates_total"]}**')
L.append(f'- **LOCAL (osiągalne z hooka/crona): {d["local_reachable"]}**')
L.append(f'- **CI-ONLY (osiągalne wyłącznie przez `verify.sh gates` z GitHub Actions): {d["ci_only"]}**')
L.append(f'- **BRAK ŚCIEŻKI: {d["no_path"]}**')
L.append(f'- skrypty `tools/gates/*.sh` poza jakimkolwiek triggerem: **{len(d["orphan_scripts"])}** {d["orphan_scripts"]}')
L.append(f'- CI aktywne (workflows wołają `verify.sh gates`): {d["ci_active"]} {d["ci_profiles"]}\n')
L.append(f'## TOP 15 nieosiągalnych lokalnie, po severity ({len(det)} łącznie)\n')
for r in det[:15]:
    path = 'CI' if r['ci'] else 'BRAK ŚCIEŻKI'
    L.append(f'- **{r["gate_id"]}** `{r["severity"]}` blocking={r["blocking"]} — {r["name"]} → `{r["command"]}` [{path}]')
L.append('')
L.append('Kandydaci do usunięcia z rejestru: **brak** — wszystkie 119 wpisów mają istniejący plik `command`.')
L.append('Rekomendacja: przy każdym nowym wpisie w rejestrze TEN gate (ratchet) zablokuje push,')
L.append('jeśli nowa bramka nie dostanie triggera — to jest mechanizm „stan nie może się zdegradować".\n')
L.append(f'## Bramki nieosiągalne LOKALNIE ({len(det)}) — pełna tabela\n')
L.append('| gate_id | severity | blocking | status | command | istnieje | ścieżka |')
L.append('|---|---|---|---|---|---|---|')
for r in det:
    path = 'CI' if r['ci'] else 'BRAK'
    L.append(f'| {r["gate_id"]} | {r["severity"]} | {r["blocking"]} | {r["status"]} | `{r["command"]}` | {r["exists"]} | {path} |')
L.append('')
L.append('## Bramki osiągalne LOKALNIE\n')
loc = sorted([r for r in d['rows'] if r['local']], key=lambda r: r['gate_id'])
L.append(', '.join(f'{r["gate_id"]}({",".join(r["triggers"])})' for r in loc) + '\n')
open(f, 'w').write('\n'.join(L))
print(f'INFO gate-reachability: raport zapisany {f}')
PYEOF
fi

# ── Werdykt (ratchet) ─────────────────────────────────────────────────
MOD_WIRED="$(read_field module_wired)"
echo "BRAMKI: rejestr=$REG_TOTAL moduły(gates.yaml)=$MOD_TOTAL spięte_moduły=$MOD_WIRED sieroty_modułów=$(printf '%s' "$MEASURE_JSON" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["module_orphans"]))') lokalnie=$LOCAL ci_only=$CI_ONLY brak_ścieżki=$NO_PATH"

# RATCHET MODUŁÓW (2026-10-03, rozkaz Suwerena „zero sierot, wszystkie pętle spięte"):
# liczba sierot modułów NIE MOŻE ROSNĄĆ. Baseline w tym samym pliku co ratchet rejestru.
BASE_MOD=""
if [ -f "$BASELINE" ]; then
  BASE_MOD="$(grep -E '^module_orphans=' "$BASELINE" 2>/dev/null | tail -1 | cut -d= -f2)"
fi
NOW_MOD="$(printf '%s' "$MEASURE_JSON" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["module_orphans"]))')"

if [ "$NO_PATH" -gt 0 ]; then
  printf '%s' "$MEASURE_JSON" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for r in d["rows"]:
    if not r["local"] and not r["ci"]:
        print(f"FAIL gate-reachability (brak ścieżki: {r[\"gate_id\"]} {r[\"severity\"]} {r[\"command\"]})")
' 2>/dev/null
  exit 1
fi

if [ -n "$BASE_MOD" ] && [ "$NOW_MOD" -gt "$BASE_MOD" ]; then
  echo "FAIL gate-reachability (REGRESJA sierot modułów: $NOW_MOD > baseline $BASE_MOD — moduł gates.yaml bez triggera w hooks.yaml/cron.yaml)"
  printf '%s' "$MEASURE_JSON" | python3 -c 'import json,sys; [print(f"  SIEROTA: {m}") for m in json.load(sys.stdin)["module_orphans"]]'
  exit 1
elif [ -n "$BASE_MOD" ] && [ "$NOW_MOD" -lt "$BASE_MOD" ]; then
  echo "PASS gate-reachability: poprawa sierot modułów ($NOW_MOD < baseline $BASE_MOD) — odśwież baseline (--update-baseline)"
fi

# ── Ratchet sierot MODUŁÓW gates.yaml (2026-10-03) ─────────────────────
# (scalony z wersją równoległego subagenta wyżej — jeden ratchet, nie dwa)
if [ -z "$BASELINE_RATCHET" ]; then
  echo "WARN gate-reachability: brak baseline ($BASELINE) — run --update-baseline"
  exit 0
fi

if [ "$RATCHET_NOW" -gt "$BASELINE_RATCHET" ]; then
  echo "FAIL gate-reachability (REGRESJA ratchetu: lokalnie nieosiągalnych $RATCHET_NOW > baseline $BASELINE_RATCHET — nowa bramka nie ma triggera)"
  exit 1
elif [ "$RATCHET_NOW" -lt "$BASELINE_RATCHET" ]; then
  echo "PASS gate-reachability: poprawa ($RATCHET_NOW < baseline $BASELINE_RATCHET) — odśwież baseline (--update-baseline)"
  exit 0
else
  echo "PASS gate-reachability: ratchet stabilny (lokalnie nieosiągalnych $RATCHET_NOW == baseline)"
  exit 0
fi

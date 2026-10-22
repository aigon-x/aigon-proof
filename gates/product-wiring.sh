#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  tools/gates/product-wiring.sh — KANONICZNY DYSKRETOR BRAMEK PRODUKTOWYCH
#
#  ROZKAZ SUWERENA 2026-10-13: „projekty, które powinny być wpięte a nie są"
#  — każdy PRODUKT musi być wpięty w CAŁĄ kanoniczną strukturę AIGON:
#  PRAWA (config/canonical/product-<p>.yaml) + moduł (gates.yaml) + rejestr
#  (gate-registry.yaml) + trigger (hooks.yaml) + CI/CD (.github/workflows).
#
#  JEDEN dyskretor obsługuje N bramek wołanych przez cienkie adaptery
#  hook-runnera `tools/gates/<produkt>-laws.sh` (kontrakt: hook-runner uruchamia
#  WYŁĄCZNIE tools/gates/<id>.sh). Zero duplikacji logiki per produkt.
#
#  Użycie:  product-wiring.sh <produkt>
#  Kontrakt: exit 0 = PASS/WARN, exit 1 = FAIL. Idempotentny, deterministyczny.
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="${AIGON_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
P="${1:-}"
[ -n "$P" ] || { echo "FAIL product-wiring (brak nazwy produktu)"; exit 1; }

AIGON_ROOT="$ROOT" AIGON_PRODUCT="$P" python3 - <<'PY'
import os, sys, glob, yaml

root = os.environ['AIGON_ROOT']
p    = os.environ['AIGON_PRODUCT']
FAILED = 0

def pass_(m): print(f"  [PASS] {m}")
def fail(m):
    global FAILED; FAILED = 1; print(f"  [FAIL] {m}")
def info(m): print(f"  {m}")

def load(path):
    try:
        return yaml.safe_load(open(path, encoding='utf-8'))
    except Exception as e:
        return {"__err__": str(e)}

def rel(x): return x if not str(x).startswith('/') else os.path.relpath(str(x), root)

print(f"product-wiring: {p}")

# ── [1] PRAWA produktu (config/canonical/product-<p>.yaml) ──────────────────
praw_path = os.path.join(root, 'config', 'canonical', f'product-{p}.yaml')
if not os.path.isfile(praw_path):
    fail(f"[1] PRAWA: brak {rel(praw_path)}")
    praw = {}
else:
    praw = load(praw_path)
    if '__err__' in praw:
        fail(f"[1] PRAWA: {rel(praw_path)} NIE parsuje ({praw['__err__']})"); praw = {}
    elif praw.get('product') != p:
        fail(f"[1] PRAWA: product='{praw.get('product')}' != '{p}'"); praw = {}
    else:
        pass_(f"[1] PRAWA: {rel(praw_path)} parsuje, product={p}")

# ── [2] canonical_dir (dowód, że produkt istnieje na dysku) ─────────────────
cdir = praw.get('canonical_dir', '')
if cdir and os.path.isdir(cdir):
    pass_(f"[2] canonical_dir istnieje: {cdir}")
elif cdir:
    fail(f"[2] canonical_dir NIE istnieje: {cdir}")
else:
    fail("[2] brak pola canonical_dir w PRAWACH")

# ── [3] DOWÓD WDROŻENIA: artefakt deploy (compose) lub known_external ───────
compose = []
if cdir and os.path.isdir(cdir):
    compose = glob.glob(os.path.join(cdir, '**', 'docker-compose*.y*ml'), recursive=True)
ke = load(os.path.join(root, 'CANONICALITY.yaml')).get('known_external', []) or []
ke_hit = [e for e in ke if p in str(e.get('path','')) or p == str(e.get('compose_project',''))]
if compose:
    pass_(f"[3] DEPLOY: {len(compose)} plik(ów) compose (np. {rel(compose[0])})")
elif ke_hit:
    pass_(f"[3] DEPLOY: known_external ({ke_hit[0].get('compose_project') or ke_hit[0].get('container')})")
else:
    fail("[3] DEPLOY: brak compose i brak wpisu known_external")

# ── [4] każde PRAWO ma WYKONAWCĘ (enforcer istnieje na dysku) ───────────────
laws = praw.get('laws', []) or []
if not laws:
    fail("[4] brak laws[] w PRAWACH (produkt bez praw = brak wykonawcy)")
missing = []
for law in laws:
    e = law.get('enforcer', '')
    for one in ([e] if isinstance(e, str) else (e or [])):
        one = (one or '').strip()
        if one and '*' not in one and not os.path.isfile(os.path.join(root, one)):
            missing.append(one)
if missing:
    fail(f"[4] enforcery bez pliku: {', '.join(sorted(missing))}")
else:
    pass_(f"[4] wszystkie {len(laws)} praw ma enforcer na dysku")

# ── [5] bramki-prawa mają trigger w hooks.yaml ──────────────────────────────
hooks = (load(os.path.join(root, 'config', 'canonical', 'hooks.yaml')) or {}).get('hooks', {}) or {}
wired = {g for s in hooks.values() for g in (s or {}).get('gates') or []}
need = sorted({g for b in praw.get('bindings', []) or [] for g in b.get('gates', [])})
unwired = [g for g in need if g not in wired]
if unwired:
    fail(f"[5] bramki-prawa bez triggera w hooks.yaml: {', '.join(unwired)}")
elif need:
    pass_(f"[5] wszystkie bramki-prawa mają trigger ({', '.join(need)})")
else:
    fail("[5] brak bindings[].gates w PRAWACH")

# ── [6] moduł w gates.yaml ──────────────────────────────────────────────────
gates_yaml = load(os.path.join(root, 'config', 'canonical', 'gates.yaml'))
mods = {g.get('module') for g in (gates_yaml.get('gates', []) or [])}
mod_name = f"{p}-laws"
if mod_name in mods:
    pass_(f"[6] moduł '{mod_name}' obecny w gates.yaml")
else:
    fail(f"[6] brak modułu '{mod_name}' w gates.yaml")

# ── [7] wpis w gate-registry.yaml ───────────────────────────────────────────
reg = load(os.path.join(root, 'config', 'canonical', 'gate-registry.yaml')).get('gates', []) or []
reg_hit = [g for g in reg if g.get('command', '').endswith(f"tools/gates/{mod_name}.sh")]
if reg_hit:
    pass_(f"[7] rejestr: {reg_hit[0].get('gate_id')} -> tools/gates/{mod_name}.sh")
else:
    fail(f"[7] brak wpisu w gate-registry.yaml dla tools/gates/{mod_name}.sh")

# ── [8] DOWÓD CI: job w .github/workflows odnoszący się do produktu ─────────
ci_hits = []
for wf in glob.glob(os.path.join(root, '.github', 'workflows', '*.y*ml')):
    try:
        txt = open(wf, encoding='utf-8', errors='replace').read()
    except OSError:
        continue
    if mod_name in txt or f"product-wiring" in txt and p in txt:
        ci_hits.append(os.path.basename(wf))
if ci_hits:
    pass_(f"[8] CI: {', '.join(sorted(set(ci_hits)))} woła {mod_name}")
else:
    fail(f"[8] CI: żaden workflow nie woła {mod_name}")

print(f"WYNIK: {'PASS' if FAILED == 0 else 'FAIL'} — product-wiring {p}")
sys.exit(0 if FAILED == 0 else 1)
PY

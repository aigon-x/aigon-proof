#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/repo-completeness.sh — gate repo-completeness
#
#  AUTOMAT: „Co repo DEKLARUJE, musi byc w repo SLEDZONE" — porownuje
#  deklaracje (Cargo.toml members, /etc/cron.d/aigon-cron, rejestr
#  PIPELINES) z zawartoscia INDEKSU gita, a nie z dyskiem.
#
#  DLACZEGO (zmierzone 2026-09-09): commit a6a15eb9 dopisal do members
#  w Cargo.toml crate'y aigon-kernel-offsec i aigon-kernel-hardening,
#  ale katalogow ze zrodlami nigdy nie `git add`-owal. Obraz production
#  zbudowal sie (zrodla lezaly na dysku), 31/31 kerneli bylo healthy,
#  a swiezy klon nie budowal sie w ogole — cargo padalo na nieistniejacym
#  czlonie workspace.
#
#  Wszystkie 6 bramek pre-commit przepuscilo to bez slowa, bo 39 z 40
#  bramek skanuje DYSK, a commit zapisuje INDEKS. Plik lezacy na dysku
#  i nigdy nie dodany do gita wyglada dla nich identycznie jak plik
#  zacommitowany. Ta bramka zamyka dokladnie te szpare.
#
#  Ta sama klasa bledu objela 7 skryptow uruchamianych z /etc/cron.d
#  (czesc co 5 min jako root), ktorych rowniez nie bylo w repo.
#
#  Kontrakt z hook-runner.sh:
#    exit 0 = PASS (kazda deklaracja pokryta w indeksie)
#    exit 1 = FAIL (deklaracja bez pliku w indeksie)
#    exit 2 = blad srodowiska
#  Opcje: --json | --quiet
#  Allowlist: tools/gates/repo-completeness-allowlist.txt (# = komentarz)
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ALLOW="$ROOT/tools/gates/repo-completeness-allowlist.txt"
CRON="${AIGON_CRON_FILE:-/etc/cron.d/aigon-cron}"

JSON=0; QUIET=0; LIST_MISSING=0
for a in "$@"; do
  case "$a" in
    --json) JSON=1 ;;
    --quiet) QUIET=1 ;;
    --list-missing) LIST_MISSING=1 ;;
  esac
done

cd "$ROOT" || { echo "repo-completeness: brak $ROOT"; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "repo-completeness: nie repo git"; exit 2; }

TRACKED=$(mktemp); trap 'rm -f "$TRACKED"' EXIT

# ── NAPRAWA 2026-10-14: MIERZ GŁÓWNY INDEKS, NIE TYMCZASOWY INDEKS COMMITA ──
# `git commit -- <pliki>` (commit ze ścieżkami, zalecany na wspólnym indeksie)
# ustawia GIT_INDEX_FILE na indeks TYMCZASOWY = HEAD + podane ścieżki. Bramka
# czytająca `git ls-files` widziała wtedy tylko HEAD i zgłaszała FAIL na plikach,
# które SĄ w indeksie repo (staged przez inne sesje), ale nie ma ich w HEAD.
# Zmierzone 2026-10-14: w tym kontekście FAIL na 2 deklaracjach, przy tym samym
# drzewie PASS w uruchomieniu bezpośrednim; commit odrzucony 4x (treadmill
# opisany w nagłówku scripts/repo-completeness-autofix.sh). Jedynym commitem,
# który przechodził, był commit CAŁEGO indeksu — czyli zamiecenie cudzej pracy.
# Ta zmiana wymusza pomiar indeksu repozytorium. NIE osłabia bramki: deklaracja
# nadal musi być w indeksie (tracked albo staged); plik wyłącznie na dysku
# dalej daje FAIL (test negatywny w komentarzu PR przy zmianie).
GITDIR=$(git rev-parse --absolute-git-dir 2>/dev/null) || { echo "repo-completeness: brak git-dir"; exit 2; }
GIT_INDEX_FILE="$GITDIR/index" git ls-files -z | tr '\0' '\n' > "$TRACKED" \
  || { echo "repo-completeness: git ls-files padl"; exit 2; }

ROOT="$ROOT" ALLOW="$ALLOW" CRON="$CRON" TRACKED="$TRACKED" JSON="$JSON" QUIET="$QUIET" \
LIST_MISSING="$LIST_MISSING" python3 <<'PY'
import json, os, re, subprocess, sys

root    = os.environ['ROOT']
allowp  = os.environ['ALLOW']
cronp   = os.environ['CRON']
as_json = os.environ['JSON'] == '1'
quiet   = os.environ['QUIET'] == '1'
list_missing = os.environ.get('LIST_MISSING') == '1'

tracked = set()
tracked_dirs = set()
with open(os.environ['TRACKED']) as fh:
    for line in fh:
        p = line.rstrip('\n')
        if not p:
            continue
        tracked.add(p)
        parts = p.split('/')
        for i in range(1, len(parts)):
            tracked_dirs.add('/'.join(parts[:i]))

allow = set()
if os.path.exists(allowp):
    for line in open(allowp):
        line = line.split('#', 1)[0].strip()
        if line:
            allow.add(line)

viol, checked = [], 0

def rel(p):
    p = p.replace('/opt/PROD/', '').lstrip('./')
    return p

def require(path, source, kind):
    """Sciezka zadeklarowana przez `source` musi byc w indeksie gita."""
    global checked
    p = rel(path)
    if not p or p in allow:
        return
    # KANON 2026-09-22: sciezka IGNOROWANA przez .gitignore jest poza indeksem
    # Z POLITYKI, wiec NIE jest naruszeniem. `wojsko/` (.gitignore:259) to
    # obszar DEFAULT DENY — "decyzja Suwerena wymagana" — wiec repo swiadomie
    # go nie trzyma, a bramka wymagala pliku P-131 wojsko-gate.sh. Bez tego
    # kazda przyszla, zamierzona ignorancja dawalaby falszywy FAIL.
    try:
        if subprocess.run(['git', 'check-ignore', '-q', p], cwd=root,
                          stdin=subprocess.DEVNULL).returncode == 0:
            return
    except OSError:
        pass
    checked += 1
    if p in tracked or p in tracked_dirs:
        return
    on_disk = os.path.exists(os.path.join(root, p))
    viol.append({'path': p, 'source': source, 'kind': kind,
                 'on_disk': on_disk})

# ── 1. Cargo.toml: czlony workspace ────────────────────────────────────
cargo = os.path.join(root, 'Cargo.toml')
if os.path.exists(cargo):
    txt = open(cargo, encoding='utf-8', errors='replace').read()
    m = re.search(r'members\s*=\s*\[(.*?)\]', txt, re.S)
    if m:
        for member in re.findall(r'"([^"]+)"', m.group(1)):
            if '*' in member:
                continue
            require(member, 'Cargo.toml:members', 'workspace-member')

# ── 2. cron: kazdy skrypt /opt/PROD/... ma byc w repo ──────────────────
if os.path.isfile(cronp) and os.access(cronp, os.R_OK):
    for line in open(cronp, encoding='utf-8', errors='replace'):
        s = line.strip()
        if not s or s.startswith('#'):
            continue
        for hit in re.findall(r'/opt/PROD/[\w./\-]+\.(?:sh|py)', s):
            require(hit, os.path.basename(cronp), 'cron-script')

# ── 3. rejestr PIPELINES ───────────────────────────────────────────────
pipes = os.path.join(root, 'runtime/pipelines/core/pipelines.sh')
if os.path.exists(pipes):
    for line in open(pipes, encoding='utf-8', errors='replace'):
        s = line.strip()
        if not s.startswith('"P-'):
            continue
        f = s.strip('"').split('|')
        if len(f) < 3:
            continue
        # Rejestr ma DWIE tablice o prefiksie "P- : podstawowa
        # (id|FAMILY|script|...) i rozszerzona (id|schedule|schedule_spec|...).
        # Tylko podstawowa ma w polu 1 NAZWE RODZINY (UPPERCASE); w rozszerzonej
        # jest harmonogram (manual/daily/cron). Bez tego rozroznienia bramka
        # brala schedule_spec jako sciezke skryptu i FAIL-owala na prozie
        # (zmierzone 2026-09-22: P-131 "autoryzacja haslem (SHA-256) — ...").
        if not re.fullmatch(r'[A-Z][A-Z0-9_\-]*', f[1].strip()):
            continue
        script = f[2].strip()
        if not script or script.startswith('#'):
            continue
        cand = script if script.startswith('scripts/') else 'runtime/pipelines/' + script
        cand = os.path.normpath(cand)  # normalizuj ../ z deklaracji pipelines.sh (P-111: ../../scripts/ci-deploy.sh)
        require(cand, 'pipelines.sh', 'pipeline-script')

# ── 4. compose <-> expected-services: SPOJNOSC W OBIE STRONY ───────────
# Zmierzone 2026-09-27 (przy dodawaniu usługi mcp-oauth): stack-health-check.sh
# czyta expected-services.yaml i krzyczy, gdy usługa ZNIKNIE z compose — ale
# NIE sprawdza kierunku ODWROTNEGO. Nowa usługa w compose (z labelem
# `aigon.mesh: true`), której nikt nie dopisał do expected-services, jest
# NIEWIDZIALNA dla monitoringu: nie ma jej na liście kontrolnej, więc jej
# śmierć jest cicha (dokładnie klasa routera z 0ab5a258). Ta bramka zamyka
# szparę: co compose deklaruje jako usługę mesha, MUSI być w expected-services.
compose = os.path.join(root, 'docker-compose.yml')
expected = os.path.join(root, 'config/expected-services.yaml')
if os.path.exists(compose) and os.path.exists(expected):
    # required_services z expected-services (proste, jak w stack-health-check)
    declared = set()
    in_required = False
    for line in open(expected, encoding='utf-8', errors='replace'):
        s = line.rstrip('\n')
        if re.match(r'^required_services:', s):
            in_required = True
            continue
        if in_required and re.match(r'^[a-z_]+:', s):
            in_required = False
        if in_required:
            m = re.match(r'^\s*-\s*([a-z0-9][a-z0-9_\-]*)', s)
            if m:
                declared.add(m.group(1))

    # usługi compose oznaczone jako mesh (blok per serwis, top-level 2 spacje)
    txt = open(compose, encoding='utf-8', errors='replace').read()
    svc = None
    is_mesh = False
    mesh_services = set()
    for line in txt.splitlines():
        m_svc = re.match(r'^  ([a-z0-9][a-z0-9_\-]*):\s*$', line)
        if m_svc:
            if svc and is_mesh:
                mesh_services.add(svc)
            svc, is_mesh = m_svc.group(1), False
            continue
        if svc and 'aigon.mesh:' in line and '"true"' in line:
            is_mesh = True
    if svc and is_mesh:
        mesh_services.add(svc)

    for s in sorted(mesh_services):
        if s in allow:
            continue
        checked += 1
        if s not in declared:
            viol.append({
                'path': f'config/expected-services.yaml (brak wpisu: {s})',
                'source': 'docker-compose.yml (aigon.mesh: true)',
                'kind': 'service-not-monitored',
                'on_disk': True,
            })

# --list-missing: wypluc WYLACZNIE sciezki mozliwe do `git add` (jedna na linie).
# Autofix reaktora: `bash repo-completeness.sh --list-missing | xargs -r git add --`.
if list_missing:
    for v in viol:
        if v.get('on_disk') and re.fullmatch(r'[\w./\-]+', v['path']):
            print(v['path'])
    sys.exit(0)

status = 'FAIL' if viol else 'PASS'
if as_json:
    print(json.dumps({'gate': 'repo-completeness', 'status': status,
                      'checked': checked, 'violations': viol},
                     ensure_ascii=False, indent=2))
elif not quiet:
    if viol:
        print(f"repo-completeness: FAIL — {len(viol)} deklaracji bez pliku w indeksie gita (sprawdzono {checked})")
        for v in viol:
            gdzie = 'LEZY NA DYSKU, ale nie dodany do gita' if v['on_disk'] else 'NIE ISTNIEJE'
            print(f"  {v['source']} -> {v['path']} ({v['kind']}: {gdzie})")
        print("  Napraw: `git add <sciezka>` albo dopisz do tools/gates/repo-completeness-allowlist.txt z uzasadnieniem.")
    else:
        print(f"repo-completeness: PASS — {checked} deklaracji, wszystkie w indeksie")

sys.exit(1 if viol else 0)
PY

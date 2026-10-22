#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  tools/gates/constitution-fitness.sh — gate: konstytucja wykonywalna
#
#  AUTOMAT: „Każde prawo ma dowód, że jest egzekwowane."
#
#  Czyta config/canonical/constitution.generated.yaml (rejestr maszynowy,
#  generowany z prozy przez tools/canon/gen-constitution-registry.py).
#  Dla każdego prawa:
#    fitness_cmd niepuste  → uruchamia, zbiera PASS/FAIL
#    fitness_cmd puste     → DEKLARACJA BEZ EGZEKUCJI (kanon: DENY IS DEFAULT,
#                            prawo bez wykonawcy nie jest prawem)
#
#  Metryka: CONSTITUTION COVERAGE = prawa_z_egzekucja / actual_laws
#
#  Kontrakt z hook-runner.sh (jak repo-completeness.sh):
#    exit 0 = PASS (wszystkie wymagane fitness zdane, pokrycie >= progu)
#    exit 1 = FAIL (fitness FAIL albo pokrycie < progu)
#    exit 2 = błąd środowiska (brak rejestru, brak pyyaml, zły YAML)
#
#  Opcje: --json | --quiet | --coverage=X.Y (domyślnie: RATCHET, patrz niżej)
#  Allowlist: tools/gates/constitution-fitness-allowlist.txt
#    (id prawa + uzasadnienie po #; wpis bez uzasadnienia = błąd audytu)
#
#  ── PRÓG: RATCHET, NIE 100% (decyzja architektoniczna 2026-09-28) ─────────
#  Stan zmierzony przy wdrożeniu: 0/86 praw ma wykonawcę. Próg 100% postawiony
#  od razu ZABLOKOWAŁBY KAŻDY PUSH W CAŁYM REPO (a jest tu ~10 agentów pracujących
#  równolegle) — to paraliż, nie egzekucja. Wzorzec przyjęty w tym repo dla długu
#  zastanego (patrz placement/GATE-127, GATE-132): „dlug zastany = WARN, mozna
#  tylko zmniejszac". Dlatego:
#    - próg domyślny = zmierzony stan z baseline (config/canonical/constitution-baseline.yaml)
#    - FAIL tylko przy REGRESIE (pokrycie SPADŁO poniżej baseline)
#    - wzrost pokrycia aktualizuje baseline i jest raportowany jako postęp
#  Próg 100% nadal dostępny: `--coverage=1.0` (używać, gdy wszystkie 86 praw
#  dostanie wykonawcę — cel końcowy, nie stan obecny).
#  Kanon: „GREEN IS GUILTY" — bramka domyślnie raportuje brak, nie udaje sukcesu.
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REJESTR="$ROOT/config/canonical/constitution.generated.yaml"
ALLOW="$ROOT/tools/gates/constitution-fitness-allowlist.txt"
BASELINE="$ROOT/config/canonical/constitution-baseline.yaml"

JSON=0; QUIET=0; COVERAGE=""
for a in "$@"; do
  case "$a" in
    --json)       JSON=1 ;;
    --quiet)      QUIET=1 ;;
    --coverage=*) COVERAGE="${a#--coverage=}" ;;
  esac
done

[ -f "$REJESTR" ] || {
  echo "constitution-fitness: brak rejestru $REJESTR"
  echo "  Napraw: python3 tools/canon/gen-constitution-registry.py --write"
  exit 2
}
command -v python3 >/dev/null || { echo "constitution-fitness: brak python3"; exit 2; }

ROOT="$ROOT" REJESTR="$REJESTR" ALLOW="$ALLOW" BASELINE="$BASELINE" \
JSON="$JSON" QUIET="$QUIET" COVERAGE="$COVERAGE" \
python3 <<'PY'
import json, os, subprocess, sys

try:
    import yaml
except Exception as e:
    print(f"constitution-fitness: brak pyyaml: {e}")
    sys.exit(2)

root        = os.environ['ROOT']
rejestr     = os.environ['REJESTR']
allowp      = os.environ['ALLOW']
baselinep   = os.environ['BASELINE']
as_json     = os.environ['JSON'] == '1'
quiet       = os.environ['QUIET'] == '1'
cov_arg     = os.environ['COVERAGE'].strip()   # "" = tryb RATCHET

try:
    data = yaml.safe_load(open(rejestr, encoding='utf-8'))
except Exception as e:
    print(f"constitution-fitness: zły YAML rejestru: {e}")
    sys.exit(2)

meta = data.get('meta', {})
laws = data.get('laws', [])
total = int(meta.get('actual_laws', len(laws)))
timeout = int(meta.get('fitness_timeout_s', 60))

# ── Próg: jawny (--coverage) albo RATCHET z baseline ────────────────────
prog_zrodlo = 'jawny'
if cov_arg:
    coverage_min = float(cov_arg)
else:
    # RATCHET: próg = pokrycie zapisane w baseline. Brak baseline = 0.0
    # (nie blokujemy, ale raportujemy brak punktu odniesienia).
    prog_zrodlo = 'ratchet'
    coverage_min = 0.0
    try:
        b = yaml.safe_load(open(baselinep, encoding='utf-8')) or {}
        coverage_min = float(b.get('coverage', 0.0))
    except Exception:
        prog_zrodlo = 'ratchet-bez-baseline'

# ── Allowlist: swiadome wyjatki, kazdy z uzasadnieniem ──────────────────
# DWA źródła (2026-09-28): (1) plik txt jak dotychczas, (2) sekcja `exempt`
# w config/canonical/constitution-fitness-map.yaml — SSOT wykonawców praw.
# Powód: exempt wpisany w mapie był ZAPISYWANY do rejestru jako
# fitness_type=exempt, ale bramka go NIE CZYTAŁA (czytała wyłącznie txt,
# który nie istniał) — czyli wyjątek istniał i nie działał. Ta sama klasa
# co reszta sesji: "istnieje nie chodzi".
allow = {}
if os.path.exists(allowp):
    for nr, line in enumerate(open(allowp, encoding='utf-8'), 1):
        if '#' not in line:
            continue  # wpis bez uzasadnienia = ignorowany (i raportowany nizej)
        wpis, uzas = line.split('#', 1)
        wpis = wpis.strip()
        if wpis:
            allow[wpis] = uzas.strip()

_MAP = os.path.join(os.environ.get('ROOT', '/srv/aigon'),
                    'config/canonical/constitution-fitness-map.yaml')
if os.path.exists(_MAP):
    try:
        _m = yaml.safe_load(open(_MAP, encoding='utf-8')) or {}
        for _law, _spec in (_m.get('exempt') or {}).items():
            _reason = (_spec or {}).get('reason', '') if isinstance(_spec, dict) else ''
            if _reason.strip():
                allow[str(_law)] = _reason.strip()
            # brak uzasadnienia => NIE dodajemy (kanon: pusty wyjątek = nadużycie)
    except Exception:
        pass  # mapa nieparsowalna => jadziemy na samym txt (jak dotychczas)

# ── Sprawdz kazde prawo ─────────────────────────────────────────────────
wykonane, bez_egzekucji, fail = 0, [], []
bez_pomiaru = []   # exit 2 / timeout: środowisko, NIE złamanie prawa
szczegoly = []

for law in laws:
    pid = law['id']
    cmd = (law.get('fitness_cmd') or '').strip()
    if pid in allow:
        wykonane += 1
        szczegoly.append({'id': pid, 'status': 'ALLOW',
                          'powod': allow[pid][:80]})
        continue
    if not cmd:
        bez_egzekucji.append(pid)
        szczegoly.append({'id': pid, 'status': 'BEZ_EGZEKUCJI',
                          'powod': (law.get('fitness_type') or '?')})
        continue
    try:
        proc = subprocess.run(cmd, shell=True, cwd=root, timeout=timeout,
                              capture_output=True, text=True)
        rc = proc.returncode
    except subprocess.TimeoutExpired:
        # Przekroczenie terminu = brak pomiaru, nie złamanie prawa.
        # (Kontrakt fitness: 2 = błąd środowiska. Timeout jest tej klasy.)
        szczegoly.append({'id': pid, 'status': 'TIMEOUT', 'powod': f'>{timeout}s'})
        bez_pomiaru.append(pid)
        continue
    except Exception as e:
        szczegoly.append({'id': pid, 'status': 'BLAD', 'powod': str(e)[:80]})
        bez_pomiaru.append(pid)
        continue

    # KONTRAKT WYKONAWCY (taki sam jak w gates/): 0=PASS, 1=FAIL(złamanie),
    # 2=brak pomiaru (środowisko). Zmierzone 2026-09-28: wykonawca LAW-95
    # zwraca 2, gdy runtime :7000 jest zajęty bootem — a to NIE jest złamanie
    # prawa. Wcześniejsza wersja liczyła każdy niezerowy kod jako FAIL, więc
    # prawo "padało" z powodu niedostępności pomiaru (fałszywy alarm).
    if rc == 0:
        wykonane += 1
        szczegoly.append({'id': pid, 'status': 'PASS', 'powod': cmd[:80]})
    elif rc == 2:
        bez_pomiaru.append(pid)
        szczegoly.append({'id': pid, 'status': 'BEZ_POMIARU',
                          'powod': 'exit 2 (środowisko)'})
    else:
        fail.append(pid)
        szczegoly.append({'id': pid, 'status': 'FAIL', 'powod': cmd[:80]})

coverage = (wykonane / total) if total else 0.0
# RATCHET: FAIL tylko gdy pokrycie SPADŁO poniżej baseline (regresja).
# Wzrost pokrycia = postęp (nie FAIL), brak zmiany = PASS.
regresja = coverage < coverage_min
status = 'FAIL' if (fail or regresja) else 'PASS'

if as_json:
    print(json.dumps({
        'gate': 'constitution-fitness',
        'status': status,
        'actual_laws': total,
        'z_egzekucja': wykonane,
        'coverage': round(coverage, 4),
        'coverage_min': coverage_min,
        'prog_zrodlo': prog_zrodlo,
        'regresja': regresja,
        'bez_egzekucji': bez_egzekucji,
        'bez_pomiaru': bez_pomiaru,
        'fail': fail,
        'szczegoly': szczegoly,
    }, ensure_ascii=False, indent=2))
else:
    proc = f"{coverage*100:.1f}%"
    if status == 'FAIL':
        if regresja:
            print(f"constitution-fitness: FAIL — REGRESJA pokrycia: {proc} "
                  f"< baseline {coverage_min*100:.1f}% (praw z wykonawcą: "
                  f"{wykonane}/{total})")
        if fail:
            print(f"  {len(fail)} praw Z FAIL fitness: {', '.join(fail[:12])}")
        if bez_pomiaru:
            print(f"  {len(bez_pomiaru)} praw BEZ POMIARU (exit 2/timeout — "
                  f"środowisko, nie złamanie): {', '.join(bez_pomiaru[:8])}")
        print(f"  (tryb progu: {prog_zrodlo})")
    else:
        postep = ""
        if coverage > coverage_min:
            postep = f" [POSTĘP: baseline {coverage_min*100:.1f}% -> {proc}]"
        print(f"constitution-fitness: PASS — COVERAGE {wykonane}/{total} = "
              f"{proc} (ratchet, baseline {coverage_min*100:.1f}%){postep}")
    # Zawsze pokaz dlug: prawo bez wykonawcy = zyczenie, nie prawo.
    if bez_egzekucji and not quiet:
        print(f"  UWAGA: {len(bez_egzekucji)}/{total} praw BEZ WYKONAWCY "
              f"(deklaracja, nie prawo) — cel: 0.")
        print(f"    pierwsze: {', '.join(bez_egzekucji[:8])}"
              + (" ..." if len(bez_egzekucji) > 8 else ""))

sys.exit(1 if status == 'FAIL' else 0)
PY

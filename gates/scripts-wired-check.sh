#!/usr/bin/env bash
# TEMPLATE-CANON G-20f: wymaga scripts/ + config/canonical/hooks.yaml
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/scripts-wired-check.sh — gate scripts-wired-check
#
#  AUTOMAT: „Napisane = PODPIĘTE" (zasada Suwerena) — rozszerzenie bramki
#  wired-check (która pilnuje wyłącznie structów w Rust) na SKRYPTY.
#
#  PO CO (root cause, zmierzone 2026-09-30):
#   Suweren: „chce tabele tych 276 skryptow i czy jest wpiete i gdzie,
#   a jesli nie to dlaczego... chuj martwy kod, podpinac, jak cos bylo
#   napisane tzn ze bylo potrzebne".
#
#   Zmierzone w /opt/PROD/scripts: 474 pliki; 436 wpięte, 38 SIEROT.
#   Sierota = nikt jej nie woła: nie ma jej w cron.yaml, backups.yaml,
#   hooks.yaml, docker-compose.yml, systemd, /etc/cron.d, tools/gates ani
#   w innym skrypcie. Taki plik NIE DZIAŁA — jest deklaracją intencji.
#
#  DETECTOR MUSI BYĆ SZEROKI (lekcja z tego samego dnia): pierwsze podejście
#  liczyło tylko pole `command:` w cron.yaml i pokazało 276 sierot — FAŁSZYWIE,
#  bo `sync-secrets.sh`, `alert-webhook-receiver.py`, `disk-emergency-reclaim.sh`
#  są wołane z allowlist w kodzie, compose i polityki alertów. Wąski detektor
#  = fałszywy alarm = nieuzasadniona „naprawa". Ten gate skanuje WSZYSTKIE
#  kanały wołania, jakie istnieją w repo.
#
#  Kontrakt z hook-runner.sh:
#    exit 0 = PASS/WARN (każda sierota ma wpis w allowliście z uzasadnieniem)
#    exit 1 = FAIL (sierota bez uzasadnienia = martwy kod)
#    exit 3 = błąd środowiska
#  Opcje:
#    --json      → raport JSON na stdout
#    --quiet     → bez stdout (tylko exit code)
#    --list      → wypisz wszystkie sieroty z klasyfikacją (tabela dla Suwerena)
#    --regen     → przepisz allowlistę aktualną listą sierot (z placeholderem)
#
#  Allowlista (uzasadnienia): config/canonical/scripts-orphans.json
#    [{"script": "x.sh", "reason": "...", "class": "lib|on-demand|test|...",
#      "wired_by_intent": "gdzie MIAŁBY być wpięty albo почему nie może"}]
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS="${AIGON_SCRIPTS_DIR:-$ROOT/scripts}"
ALLOW="${AIGON_SCRIPTS_ALLOW:-$ROOT/config/canonical/scripts-orphans.json}"
JSON=0; QUIET=0; LIST=0; REGEN=0
for a in "$@"; do
  case "$a" in
    --json) JSON=1 ;;
    --quiet) QUIET=1 ;;
    --list) LIST=1 ;;
    --regen) REGEN=1 ;;
  esac
done
[ -d "$SCRIPTS" ] || { echo "scripts-wired-check: brak $SCRIPTS"; exit 3; }

REPORT="$(ROOT="$ROOT" SCRIPTS="$SCRIPTS" ALLOW="$ALLOW" python3 - << 'PYEOF'
import json, os, re, subprocess, sys

root = os.environ["ROOT"]
sdir = os.environ["SCRIPTS"]
allow_path = os.environ["ALLOW"]

scripts = sorted(f for f in os.listdir(sdir) if f.endswith((".sh", ".py")))

# ── ZBIÓR KANAŁÓW WOŁANIA (szeroki, celowo) ───────────────────────────────
blob = []
def add_file(p):
    try:
        with open(p, "r", encoding="utf-8", errors="replace") as fh:
            blob.append(fh.read())
    except OSError:
        pass

# (1) SSOT-y repo
for rel in (
    "config/cron.yaml", "config/backups.yaml", "config/canonical/hooks.yaml",
    "config/gateways.yaml", "config/alert-automation-policy.yaml",
    "config/secrets.yaml", "config/mesh-nodes.yaml", "config/packages.yaml",
    "docker-compose.yml", "core/docker-compose.yml",
):
    add_file(os.path.join(root, rel))
# (2) wszystkie YAML-e config/ (polityki, rejestry) — Z WYKLUCZENIEM `generated/`.
#  PUŁAPKA 2 (fałszywy zielony, zmierzony 2026-09-30): `config/generated/atlas.generated.yaml`
#  to INWENTARZ — spis WSZYSTKICH skryptów w repo. Skanowanie go sprawia, że
#  KAŻDY skrypt „znajduje się" w haystacku → 0 sierot → PASS na martwym kodzie.
#  Inwentarz odpowiada na pytanie „jaki plik istnieje", NIE „kto go woła".
#  Kanał wołania to cron/compose/systemd/hook/inny skrypt — nie katalog spisu.
GENERATED = os.path.join(root, "config", "generated")
for dp, dn, fn in os.walk(os.path.join(root, "config")):
    dn[:] = [d for d in dn if d not in (".git", "node_modules")]
    if os.path.abspath(dp).startswith(GENERATED):
        continue
    for f in fn:
        if f.endswith((".yaml", ".yml", ".json")):
            add_file(os.path.join(dp, f))
# (3) bramki i narzędzia
for dp, dn, fn in os.walk(os.path.join(root, "tools")):
    dn[:] = [d for d in dn if d not in ("target", ".git", "node_modules", ".venv", ".venv-otel")]
    for f in fn:
        if f.endswith((".sh", ".py", ".mjs", ".js", ".yaml", ".yml")):
            add_file(os.path.join(dp, f))
# (4) wzajemne wołania skrypt→skrypt — ALE Z WYKLUCZENIEM SAMEGO SIEBIE.
#  PUŁAPKA (fałszywy zielony, zmierzony 2026-09-30 przy pierwszym uruchomieniu
#  tej bramki): jeśli do worka wrzucimy treść WSZYSTKICH skryptów, to każdy
#  plik znajdzie SWOJĄ WŁASNĄ nazwę w nagłówku/komentarzu → haystack zawsze
#  zawiera nazwę → 0 sierot → bramka melduje PASS na martwym kodzie.
#  Detektor musi pytać „kto INNY mnie woła", nie „czy ja o sobie wspominam".
for f in scripts:
    try:
        with open(os.path.join(sdir, f), "r", encoding="utf-8", errors="replace") as fh:
            body = fh.read()
    except OSError:
        continue
    # usuń z treści wzmianki o WŁASNEJ nazwie — inaczej autoreferencja
    body = body.replace(f, "__SELF__")
    blob.append(body)
# (5) runtime: systemd + /etc/cron.d + /etc/crontab
for cmd in ("cat /etc/cron.d/* /etc/crontab 2>/dev/null",
            "grep -rh . /etc/systemd/system/*.service /etc/systemd/system/*.timer 2>/dev/null"):
    try:
        blob.append(subprocess.run(cmd, shell=True, capture_output=True,
                                   text=True, timeout=60).stdout)
    except Exception:
        pass

haystack = "\n".join(blob)

# ── ALLOWLISTA (uzasadnione sieroty) ──────────────────────────────────────
allow = {}
snapshot_corrupt = False
if os.path.isfile(allow_path):
    try:
        data = json.load(open(allow_path, encoding="utf-8"))
        for item in (data if isinstance(data, list) else data.get("orphans", [])):
            allow[item.get("script", "")] = item
    except Exception:
        snapshot_corrupt = True

# ── KLASYFIKACJA SIEROTY (dlaczego nie jest wpięta) ───────────────────────
def classify(name, body):
    """Zwraca (klasa, sugestia). Klasa mówi CO z tym zrobić."""
    if name.startswith(("test", "test_")) or "/test" in body[:400]:
        return "test", "biblioteka testowa — wpiąć do runnera testów CI"
    if name.startswith(("lib", "_")) or "source " in body[:600] or "source \"" in body[:600]:
        return "lib", "biblioteka współdzielona — wołana przez `source` (OK)"
    low = body.lower()
    for kw, cls, sug in (
        ("jednorazow", "on-demand", "skrypt jednorazowy — wpisać do runbooka/allowlisty"),
        ("runbook", "on-demand", "element runbooka — wpiąć do dokumentacji operacyjnej"),
        ("wklej na maszynie", "on-demand", "procedura awaryjna — allowlista + runbook"),
        ("one-shot", "on-demand", "skrypt jednorazowy — allowlista z uzasadnieniem"),
    ):
        if kw in low[:1200]:
            return cls, sug
    return "unknown", "NIEZNANE — do decyzji: podpiąć do cron/hooka albo allowlista"

rows = []
for name in scripts:
    if name in haystack:
        continue
    try:
        body = open(os.path.join(sdir, name), "r", encoding="utf-8", errors="replace").read()
    except OSError:
        body = ""
    cls, sug = classify(name, body)
    a = allow.get(name)
    rows.append({
        "script": name,
        "class": (a or {}).get("class", cls),
        "reason": (a or {}).get("reason", ""),
        "suggestion": sug,
        "allowlisted": bool(a),
        "auto_class": cls,
    })

unjustified = [r for r in rows if not r["allowlisted"]]
justified = [r for r in rows if r["allowlisted"]]
wired = len(scripts) - len(rows)

# ── NAPRAWA 2026-10-01: NIEŚLEDZONY WIP ≠ NARUSZENIE KONTRAKTU ──────────────
# Zmierzone 3× w JEDNEJ sesji: nieśledzony skrypt RÓWNOLEGŁEJ sesji blokował
# pre-commit WSZYSTKIM (prompt_index.py, hermes-mesh-dashboard.sh,
# binary-integrity-guard.sh). Taki plik nie ma żadnej deklaracji w repo, więc
# nie może jej łamać — to praca w toku, nie martwy kod. Klasa: DETEKTOR ZA SZEROKI.
# Rozdzielamy: zadeklarowany-bez-wpięcia = FAIL (realny defekt), nieśledzony w
# gicie = WARN (z nazwą, do decyzji autora).
# ZABEZPIECZENIE 1: gdy git nie odpowie (brak repo/błąd), NIE przeklasyfikowuj —
# inaczej pusty zbiór zrobiłby ze WSZYSTKICH sierot „WIP" = FAŁSZYWY ZIELONY.
# ZABEZPIECZENIE 2: podstawą jest **HEAD**, nie indeks. Zmierzone 2026-10-01:
# `git ls-files` czyta INDEKS, więc plik tylko ZASTAGOWANY (`git add`, bez commita)
# wyglądał jak „zadeklarowany w repo" i dawał FAIL wszystkim. Kontrakt repo = to,
# co ZACOMMITOWANE; staged-only to wciąż praca w toku.
try:
    _gt = subprocess.run(["git", "-C", root, "ls-tree", "-r", "HEAD", "--name-only", "scripts"],
                         capture_output=True, text=True, timeout=30)
    tracked = {p.split("/", 1)[1] for p in _gt.stdout.split() if p.startswith("scripts/")}
except Exception:
    tracked = set()
wip = []
if tracked:
    wip = [r for r in unjustified if r["script"] not in tracked]
    unjustified = [r for r in unjustified if r["script"] in tracked]

report = {
    "status": "PASS" if not unjustified else "FAIL",
    "scripts_total": len(scripts),
    "scripts_wired": wired,
    "orphans_total": len(rows),
    "orphans_allowlisted": len(justified),
    "orphans_unjustified": len(unjustified),
    "orphans_wip_untracked": len(wip),
    "snapshot_corrupt": snapshot_corrupt,
    "fail_orphans": unjustified,
    "warn_orphans": justified + wip,
}
print(json.dumps(report, ensure_ascii=False))
PYEOF
)" || { echo "scripts-wired-check: analiza nie powiodła się"; exit 2; }

STATUS="$(echo "$REPORT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["status"])')"
[ -n "$STATUS" ] || { echo "scripts-wired-check: nie mogę odczytać statusu"; exit 2; }

if [ "$REGEN" = "1" ]; then
  AIGON_REPORT="$REPORT" python3 - "$ALLOW" << 'PYEOF'
import json, os, sys
path = sys.argv[1]
rep = json.loads(os.environ["AIGON_REPORT"])
out = []
for o in rep.get("fail_orphans", []) + rep.get("warn_orphans", []):
    out.append({
        "script": o["script"],
        "class": o.get("class") or o.get("auto_class", "unknown"),
        "reason": o.get("reason") or "DO UZUPELNIENIA — dlaczego nie jest wpiety",
        "wired_by_intent": o.get("suggestion", ""),
    })
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w", encoding="utf-8") as fh:
    json.dump(out, fh, indent=2, ensure_ascii=False)
print(f"scripts-wired-check: --regen — zapisano {len(out)} sierot do {path}")
PYEOF
  exit 0
fi

if [ "$JSON" = "1" ]; then
  echo "$REPORT"
elif [ "$LIST" = "1" ]; then
  AIGON_REPORT="$REPORT" python3 - << 'PYEOF'
import json, os
r = json.loads(os.environ["AIGON_REPORT"])
print(f"# SKRYPTY={r['scripts_total']} WPIETE={r['scripts_wired']} SIEROTY={r['orphans_total']} "
      f"(allowlista={r['orphans_allowlisted']}, FAIL={r['orphans_unjustified']})")
print(f"{'SKRYPT':<50} {'KLASA':<10} {'WPIETY?':<9} DLACZEGO/JAK")
print("-" * 118)
for o in r.get("fail_orphans", []):
    print(f"{o['script']:<50} {o['auto_class']:<10} {'NIE':<9} {o['suggestion']}")
for o in r.get("warn_orphans", []):
    print(f"{o['script']:<50} {o['class']:<10} {'allowlista':<9} {o['reason'][:60]}")
PYEOF
elif [ "$QUIET" != "1" ]; then
  AIGON_REPORT="$REPORT" python3 - << 'PYEOF'
import json, os
r = json.loads(os.environ["AIGON_REPORT"])
print(f"scripts-wired-check: {r['status']} — skryptow={r['scripts_total']} "
      f"wpiete={r['scripts_wired']} sieroty={r['orphans_total']} "
      f"(allowlista={r['orphans_allowlisted']}, FAIL={r['orphans_unjustified']})")
for o in r.get("fail_orphans", [])[:15]:
    print(f"  FAIL sierota: {o['script']} [{o['auto_class']}] — {o['suggestion']}")
if r.get("snapshot_corrupt"):
    print("  UWAGA: scripts-orphans.json nie jest poprawnym JSON — allowlista pusta")
PYEOF
fi

case "$STATUS" in
  PASS|WARN) exit 0 ;;
  *) exit 1 ;;
esac

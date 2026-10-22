#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
#  tools/gates/llm-flow.sh — GATE LAW-LLM-FLOW-1
#  (PRZEPŁYW LLM = CIĄGŁA OPTYMALIZACJA: szybkość × jakość × koszt × lokalność)
#
#  POWÓD ISTNIENIA (zmierzone 2026-10-18 00:48): prawo zadeklarowane przez
#  Suwerena 2026-10-17 (config/canonical/law-llm-flow.yaml) nie miało ŻADNEGO
#  egzekutora — law-gate-closure C2 zgłaszał „prawa bez bramki i bez wyjątku:
#  LAW-LLM-FLOW-1”. Wyjątek jest ZAKAZANY („tylko Suweren uchyla prawa”),
#  więc prawem trzeba było PODPIĄĆ bramkę, nie wyciszyć.
#
#  CO MIERZY (struktura SSOT, nie proza):
#    L1  config/canonical/llm-cascade.yaml istnieje i parsuje się,
#    L2  `tiers` NIE są puste i KAŻDY szczebel ma model + host
#        (kaskada bez szczebli = przepływ na pałę),
#    L3  ostatni szczebel jest KOLEJKĄ/fallbackiem (kaskada nie kończy się
#        porażką — wymóg prawa), rozpoznane po polu/etykiecie,
#    L4  `measured_matrix` istnieje i NIE jest puste (wybór POMIAREM, nie nawykiem),
#    L5  `verification` istnieje (prawo deklaruje weryfikację przepływu),
#    L6  świeżość: `updated` <= 30 dni (nieświeża macierz = wybór na ślepo).
#
#  KONTRAKT: 0 = PASS, 1 = FAIL, 2 = UNKNOWN (brak SSOT).
#  --selftest: dowód negatywny — sabotuje kopię SSOT (puste tiers) i bramka
#  MUSI to wykryć.
# ══════════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="${AIGON_ROOT:-/opt/PROD}"
CFG="$ROOT/config/canonical/llm-cascade.yaml"
LAW="LAW-LLM-FLOW-1"
[ "${1:-}" = "--selftest" ] && SELFTEST=1 || SELFTEST=0
TARGET="$CFG"
TMPDIR_SELFTEST=""

if [ "$SELFTEST" = "1" ]; then
    TMPDIR_SELFTEST="$(mktemp -d /tmp/llm-flow-selftest.XXXXXX)"
    cp "$CFG" "$TMPDIR_SELFTEST/cascade.yaml" 2>/dev/null || { echo "llm-flow selftest: FAIL — brak SSOT do sabotazu"; exit 1; }
    python3 - "$TMPDIR_SELFTEST/cascade.yaml" <<'PY'
import sys, yaml
p = sys.argv[1]
d = yaml.safe_load(open(p, encoding="utf-8")) or {}
d["tiers"] = []
yaml.safe_dump(d, open(p, "w", encoding="utf-8"), allow_unicode=True)
PY
    TARGET="$TMPDIR_SELFTEST/cascade.yaml"
fi

if [ ! -f "$TARGET" ]; then
    echo "llm-flow: UNKNOWN — brak SSOT $TARGET"
    exit 2
fi

RESULT="$(python3 - "$TARGET" <<'PY'
import sys, yaml, datetime, re
p = sys.argv[1]
try:
    d = yaml.safe_load(open(p, encoding="utf-8")) or {}
except Exception as e:
    print("FAIL|L1|SSOT nieparsowalny: %s" % str(e)[:80]); raise SystemExit(0)

fails = []
tiers = d.get("tiers") or []
if not tiers:
    fails.append("L2|tiers puste — kaskada bez szczebli")
else:
    for i, t in enumerate(tiers, 1):
        if not isinstance(t, dict):
            fails.append("L2|szczebel %d nie jest mapa" % i); continue
        if not (t.get("id") and (t.get("transport") or t.get("model") or t.get("models"))):
            fails.append("L2|szczebel %d bez id/transport (schemat SSOT: id+order+transport)" % i)
    # Ostatni szczebel = ten z NAJWYŻSZYM `order` (kaskada schodzi w dół).
    dicts = [t for t in tiers if isinstance(t, dict)]
    last = max(dicts, key=lambda t: int(t.get("order", 0))) if dicts else {}
    blob = (str(last.get("id", "")) + " " + str(last.get("policy", "")) + " " +
            str(last.get("transport", "")) + " " + str(last.get("kind", ""))).lower()
    if not re.search(r"queue|kolejk|fallback|retry|zapas|dead.?letter", blob):
        fails.append("L3|ostatni szczebel nie wyglada na kolejke/fallback (kaskada MUSI moc czekac, nie padac)")

if not (d.get("measured_matrix") or d.get("matrix")):
    fails.append("L4|brak measured_matrix — wybor musi byc POMIAREM, nie nawykiem")

if not d.get("verification"):
    fails.append("L5|brak sekcji verification")

upd = str(d.get("updated") or "")
m = re.match(r"(\d{4})-(\d{2})-(\d{2})", upd)
if not m:
    fails.append("L6|brak pola updated (YYYY-MM-DD) — nie da sie zmierzyc swiezosci")
else:
    try:
        dt = datetime.date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
        age = (datetime.date.today() - dt).days
        if age > 30:
            fails.append("L6|macierz nieaktualna: %d dni (>30)" % age)
    except Exception:
        fails.append("L6|updated nie jest poprawna data")

if fails:
    for f in fails:
        print("FAIL|" + f)
else:
    print("PASS|%d szczebli, macierz pomiarowa obecna, swiezosc OK" % len(tiers))
PY
)"

if printf '%s' "$RESULT" | grep -q '^PASS|'; then
    if [ "$SELFTEST" = "1" ]; then
        echo "llm-flow selftest: FAIL — sabotaż (puste tiers) NIE został wykryty"
        rm -rf "$TMPDIR_SELFTEST"; exit 1
    fi
    echo "llm-flow: PASS ($LAW) — $(printf '%s' "$RESULT" | sed 's/^PASS|//')"
    exit 0
fi

if [ "$SELFTEST" = "1" ]; then
    echo "llm-flow selftest: PASS (sabotaż wykryty: $(printf '%s' "$RESULT" | head -1 | sed 's/^FAIL|//'))"
    rm -rf "$TMPDIR_SELFTEST"; exit 0
fi

echo "llm-flow: FAIL ($LAW):"
printf '%s\n' "$RESULT" | sed 's/^FAIL|/  /'
exit 1

#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
#  tools/gates/project-visual-verification.sh — WYKONAWCA PRAWA LAW-VERIFY-1
#
#  PRAWO (config/canonical/project-verification.yaml, rozkaz Suwerena
#  2026-10-06): weryfikacja PROJEKTÓW/PRODUKTÓW (strony, dashboardy, UI,
#  landingi) odbywa się PRZEGLĄDARKĄ + WIZUALNIE (screenshot/snapshot),
#  NIE samym curl ani samym statusem HTTP. „200" NIE DOWODZI, ŻE PROJEKT
#  DZIAŁA — strona może zwracać 200 i być biała/pusta/zepsuta.
#
#  KONTRAKT (identyczny jak inne fitness w constitution-fitness.sh):
#    exit 0 = PASS (prawo przestrzegane: dowód wizualny w raportach)
#    exit 1 = FAIL (prawo złamane: weryfikacja oparta WYŁĄCZNIE na curl/status)
#    exit 2 = WARN (brak pomiaru: brak raportów weryfikacji do oceny)
#
#  CO MIERZY (dowód, nie deklaracja):
#    1. NARZĘDZIE — `agent-browser` zainstalowany. Bez przeglądarki prawo
#       nie może być wykonywane => FAIL (luka infrastrukturalna, nie WARN).
#    2. SSOT — config/canonical/project-verification.yaml istnieje i wskazuje
#       tę bramkę (kanon połączony, nie „życzenie").
#    3. DOWÓD WERYFIKACJI — skan raportów/ledgera pod wzorzec false-green:
#       wpis twierdzący „działa/zweryfikowano" dla projektu/domeny, którego
#       JEDYNYM dowodem jest curl/status HTTP, BEZ dowodu wizualnego
#       (screenshot/snapshot/agent-browser/przeglądarka). Taki wpis = FAIL.
#
#  TEST NEGATYWNY: tools/gates/test_project_visual_verification_negative.sh
#  (wstrzykuje raport curl-only → bramka MUSI zwrócić exit 1; raport z
#   screenshotem → bramka NIE może zwrócić exit 1).
#
#  Opcje: --json | --quiet
#  Env (do testu / CI): AIGON_PROJECT_VERIFY_EVIDENCE=ścieżka do pliku/katalogu
#   z raportami weryfikacji (nadpisuje domyślny skan leddera).
# ══════════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
JSON=0; QUIET=0
for a in "$@"; do
  case "$a" in
    --json) JSON=1 ;;
    --quiet) QUIET=1 ;;
  esac
done

# ── 1. NARZĘDZIE: agent-browser musi istnieć ─────────────────────────────
BROWSER_BIN=""
if command -v agent-browser >/dev/null 2>&1; then
  BROWSER_BIN="$(command -v agent-browser)"
fi

# ── 2. SSOT: project-verification.yaml istnieje i wskazuje tę bramkę ────
SSOT="$ROOT/config/canonical/project-verification.yaml"
SSOT_OK=0
if [ -f "$SSOT" ] && grep -q 'project-visual-verification.sh' "$SSOT" 2>/dev/null; then
  SSOT_OK=1
fi

# ── 3. DOWÓD WERYFIKACJI: skan pod curl-only (bez dowodu wizualnego) ─────
# Źródła dowodów: jawnie wskazany plik/katalog (test/CI) albo ledger agentów.
declare -a SRC=()
if [ -n "${AIGON_PROJECT_VERIFY_EVIDENCE:-}" ]; then
  if [ -d "$AIGON_PROJECT_VERIFY_EVIDENCE" ]; then
    while IFS= read -r f; do SRC+=("$f"); done < <(find "$AIGON_PROJECT_VERIFY_EVIDENCE" -maxdepth 2 -type f 2>/dev/null)
  elif [ -f "$AIGON_PROJECT_VERIFY_EVIDENCE" ]; then
    SRC+=("$AIGON_PROJECT_VERIFY_EVIDENCE")
  fi
else
  while IFS= read -r f; do SRC+=("$f"); done < <(find "$HOME/.aigon/todo" -maxdepth 1 -name '*.ndjson' -type f 2>/dev/null)
fi

# Klasyfikacja rekordu: claim weryfikacyjny (projekt/domena + asercja sukcesu)
# vs dowód wizualny vs curl-only. Zwraca wiersze: CLAIM|VISUAL|CURLONLY.
CLASSIFIED="$(python3 - "${SRC[@]}" <<'PYEOF' 2>/dev/null
import sys, os, json

URL_RE = ("http://", "https://", "szamani.ai", "aigon.dev", ".onion")
PROJ_RE = ("projekt", "produkt", "domena", "strona", "landing", "dashboard",
           "frontend", "www", "ui ", "panel")
SUCCESS_RE = ("działa", "zweryfikowano", "zweryfikowany", "verified",
              "sprawdzono", "sprawdził", "sprawdzam", "dostarczone",
              "dostarczon", "poprawnie", "jest ok", "wszystko ok")
VISUAL_RE = ("screenshot", "snapshot", "agent-browser", "zrzut", "visual",
             "przeglądar", "przeklik", "render", "screen shot")
CURL_RE = ("curl", "http_code", "wget", "status 200", "200 ok",
           "status_code", "http 200", "http-200")

srcs = []
for p in sys.argv[1:]:
    if os.path.isfile(p):
        srcs.append(p)

def lower(s):
    return (s or "").lower()

records = []  # (source, line_no, text)
for p in srcs:
    try:
        with open(p, "r", errors="ignore") as fh:
            for i, line in enumerate(fh, 1):
                line = line.rstrip("\n")
                if not line.strip():
                    continue
                text = line
                # ndjson: weź pole text/goal/run_status zamiast surowej linii
                if line.lstrip().startswith("{"):
                    try:
                        o = json.loads(line)
                        text = " ".join(str(o.get(k, "")) for k in
                                        ("text", "goal", "run_status", "status"))
                    except Exception:
                        pass
                records.append((p, i, lower(text)))
    except OSError:
        continue

claims = 0
violations = []
for src, ln, t in records:
    has_url = any(m in t for m in URL_RE)
    has_proj = any(m in t for m in PROJ_RE)
    has_success = any(m in t for m in SUCCESS_RE)
    if not ((has_url or has_proj) and has_success):
        continue
    claims += 1
    has_visual = any(m in t for m in VISUAL_RE)
    has_curl = any(m in t for m in CURL_RE)
    # False-green = twierdzenie sukcesu projektu, dowód wyłącznie curl/status,
    # bez JAKIEGOKOLWIEK dowodu wizualnego.
    if has_curl and not has_visual:
        violations.append((src, ln, t[:200]))

print(json.dumps({"claims": claims, "violations": violations}, ensure_ascii=False))
PYEOF
)"

CLAIMS=0
VIOLATIONS="[]"
if [ -n "$CLASSIFIED" ]; then
  CLAIMS="$(echo "$CLASSIFIED" | python3 -c 'import sys,json;print(json.load(sys.stdin)["claims"])' 2>/dev/null || echo 0)"
  VIOLATIONS="$(echo "$CLASSIFIED" | python3 -c 'import sys,json;print(json.dumps(json.load(sys.stdin)["violations"],ensure_ascii=False))' 2>/dev/null || echo '[]')"
fi
NVIOL="$(echo "$VIOLATIONS" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)"

# ── Ocena ────────────────────────────────────────────────────────────────
VIOL_STR=""
if [ "$BROWSER_BIN" = "" ]; then
  VIOL_STR="$VIOL_STR agent-browser NIE zainstalowany (prawo wymaga przeglądarki);"
fi
if [ "$SSOT_OK" = "0" ]; then
  VIOL_STR="$VIOL_STR SSOT project-verification.yaml nie wskazuje bramki;"
fi
if [ "$NVIOL" -gt 0 ]; then
  VIOL_STR="$VIOL_STR $NVIOL raport(ów) weryfikacji z dowodem wyłącznie curl/status (bez visual);"
fi

STATUS="PASS"
[ -n "$VIOL_STR" ] && STATUS="FAIL"
# Brak jakiegokolwiek raportu weryfikacji + brak naruszeń = brak pomiaru (WARN).
if [ "$STATUS" = "PASS" ] && [ "$CLAIMS" = "0" ]; then
  STATUS="WARN"
fi

if [ "$JSON" = "1" ]; then
  python3 -c "
import json,sys
viol=json.loads('''$VIOLATIONS''')
print(json.dumps({'gate':'project-visual-verification','status':'$STATUS',
  'agent_browser': bool(len('''$BROWSER_BIN''')>0),
  'ssot_connected': bool($SSOT_OK),
  'claims': $CLAIMS, 'violations': len(viol)}, ensure_ascii=False))
"
elif [ "$QUIET" = "0" ]; then
  echo "[$STATUS] project-visual-verification — LAW-VERIFY-1 (Weryfikacja projektów: przeglądarka + visual)"
  echo "       agent-browser:  $([ -n "$BROWSER_BIN" ] && echo "TAK ($BROWSER_BIN)" || echo "NIE (BRAK)")"
  echo "       SSOT wpięte:    $([ "$SSOT_OK" = "1" ] && echo TAK || echo NIE)"
  echo "       raporty weryfikacji: claims=$CLAIMS curl-only=$NVIOL"
  if [ "$NVIOL" -gt 0 ]; then
    echo "$VIOLATIONS" | python3 -c '
import sys,json
for s,ln,t in json.load(sys.stdin):
    print(f"       ZŁAMANIE [{s}:{ln}] {t}")
' 2>/dev/null
  fi
  if [ -n "$VIOL_STR" ]; then
    echo "       przyczyna:$VIOL_STR"
  fi
fi

case "$STATUS" in
  PASS) exit 0 ;;
  FAIL) exit 1 ;;
  WARN) exit 2 ;;
esac

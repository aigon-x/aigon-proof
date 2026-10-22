#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  tools/gates/memory-first.sh — GATE MEMORY-FIRST (egzekwuje LAW-MEM-1)
#
#  PRAWO (SSOT: config/canonical/agent-memory.yaml → enforcement):
#    "Najpierw pamięć i baza, potem dysk." Zanim agent zacznie szukać
#    czegokolwiek, przechodzi warstwy: pamięć → baza/rejestr → MCP →
#    dopiero pliki (ripgrep po ZNANYM zakresie, LAW-TOOL-1). Skan całego
#    dysku jako PIERWSZY krok jest zakazany.
#
#  Bramka nie deklaruje — MIERZY:
#   1) STATYCZNIE: prawo MUSI być w prompcie SSOT (marker z SSOT) — usunięcie
#      prawa z promptu łamie bramkę (prawo nie znika po cichu).
#   2) PARYTET: prawo rozsyła scripts/sync-agent-models.py do plików
#      tożsamości WSZYSTKICH agentów. Bramka wymaga JEDNEGO md5 na wspólnych
#      celach — inaczej prawo dotarło do części agentów i jest sugestią.
#   3) ŻYCIE ŹRÓDEŁ (LAW-MEM-3): każda warstwa wymieniona w prawie MUSI
#      faktycznie działać — indeks pamięci istnieje i nie jest pusty, choć
#      jeden rejestr bazy odpowiada, bramka MCP nasłuchuje. Prawo wskazujące
#      martwą bazę jest FASADĄ, nie prawem. Lista warstw NIE jest tu
#      powtórzona — bramka czyta ją z SSOT, żeby deklaracja i pomiar nie
#      mogły się rozjechać.
#
#  Kontrakt hook-runnera: exit 0 = PASS/WARN, exit 1 = FAIL.
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SSOT="${ROOT}/config/canonical/agent-memory.yaml"
PROMPT_YAML="${ROOT}/config/agent-models.yaml"
FAILS=0
WARNS=0

say()  { printf '%s\n' "$*"; }
pass() { say "[PASS] $1"; }
warn() { say "[WARN] $1"; WARNS=$((WARNS+1)); }
fail() { say "[FAIL] $1"; FAILS=$((FAILS+1)); }

say "=== GATE MEMORY-FIRST (LAW-MEM-1: pamięć i baza przed dyskiem) ==="

# ── 0. SSOT prawa musi istnieć i wskazywać TĘ bramkę ───────────────────────
if [ -r "$SSOT" ]; then
  if grep -q "LAW-MEM-1" "$SSOT" 2>/dev/null; then
    pass "prawo zadeklarowane w SSOT ($(basename "$SSOT") → LAW-MEM-1)"
  else
    fail "brak LAW-MEM-1 w $SSOT — prawo nie istnieje, nie ma czego egzekwować"
  fi
  if grep -q "tools/gates/memory-first.sh" "$SSOT" 2>/dev/null; then
    pass "SSOT wskazuje tę bramkę jako egzekwującą"
  else
    fail "SSOT nie wskazuje tools/gates/memory-first.sh — deklaracja bez bramki to dług"
  fi
else
  fail "brak SSOT $SSOT"
fi

# ── 1. Prawo MUSI być w prompcie rozsyłanym do agentów ─────────────────────
MARKER="$(sed -n 's/^[[:space:]]*marker:[[:space:]]*"\(.*\)".*/\1/p' "$SSOT" 2>/dev/null | head -1)"
[ -z "$MARKER" ] && MARKER="PRAWO PAMIĘCI"

if [ -r "$PROMPT_YAML" ]; then
  if python3 - "$PROMPT_YAML" "$MARKER" <<'PY' >/dev/null 2>&1
import sys, yaml
path, marker = sys.argv[1], sys.argv[2]
c = yaml.safe_load(open(path))["system_prompt"]["content"]
ok = (marker in c) and ("LAW-MEM-1" in c) and ("memory_search" in c) and ("rg" in c)
sys.exit(0 if ok else 1)
PY
  then
    pass "prawo jest w promptcie SSOT (marker: $MARKER, z kolejnością warstw i zakazem skanu dysku)"
  else
    fail "prompt SSOT NIE zawiera prawa (marker '$MARKER' + 'LAW-MEM-1' + warstwy) — agenci go nie dostaną"
  fi
else
  fail "brak promptu $PROMPT_YAML"
fi

# ── 2. Parytet plików tożsamości: jedno md5 na wspólnych celach ────────────
if [[ -n "${AIGON_MEMORY_IDENTITY_REPORT:-}" ]]; then
  REPORT="$(<"$AIGON_MEMORY_IDENTITY_REPORT")"
else
  REPORT="$(cd "$ROOT" && timeout 120 python3 scripts/sync-agent-models.py --render-identity 2>/dev/null)"
fi
if [ -z "$REPORT" ]; then
  fail "brak raportu parytetu (sync-agent-models.py --render-identity) — brak dowodu, nie „OK”"
else
  PER_AGENT="$(python3 - "$PROMPT_YAML" <<'PY' 2>/dev/null
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1]))
    per = ((d.get("system_prompt") or {}).get("per_agent") or {})
    print(",".join(sorted(per.keys())))
except Exception:
    print("")
PY
)"
  MD5S="$(printf '%s\n' "$REPORT" | awk -F'\t' -v skip="$PER_AGENT" '
    BEGIN { n=split(skip, s, ","); for (i=1;i<=n;i++) if (s[i]!="") excl[s[i]]=1 }
    NF>=3 && !($2 in excl) && $1!="" { print $1 }' | sort -u)"
  N_FILE="$(printf '%s\n' "$REPORT" | awk -F'\t' -v skip="$PER_AGENT" '
    BEGIN { n=split(skip, s, ","); for (i=1;i<=n;i++) if (s[i]!="") excl[s[i]]=1 }
    NF>=3 && !($2 in excl)' | grep -c .)"
  N_EXCL="$(printf '%s\n' "$REPORT" | awk -F'\t' -v skip="$PER_AGENT" '
    BEGIN { n=split(skip, s, ","); for (i=1;i<=n;i++) if (s[i]!="") excl[s[i]]=1 }
    NF>=3 && ($2 in excl)' | grep -c .)"
  N_MD5="$(printf '%s\n' "$MD5S" | grep -c .)"
  if [ "$N_MD5" = "1" ]; then
    pass "parytet tożsamości: $N_FILE plików wspólnych, JEDEN md5 (${MD5S:0:12}…) — prawo dotarło do wszystkich agentów${N_EXCL:+ (+$N_EXCL z addendum per_agent: ${PER_AGENT})}"
  elif [ "${N_MD5:-0}" -gt "1" ]; then
    fail "parytet tożsamości ZŁAMANY: $N_FILE plików wspólnych, $N_MD5 różnych md5 — prawo dotarło tylko do części agentów"
    printf '%s\n' "$REPORT" | sed 's/^/       /'
  else
    fail "parytet: brak celu do porównania (0 plików wspólnych, wykluczone per_agent: ${PER_AGENT:-brak})"
  fi
fi

# ── 3. ŻYCIE ŹRÓDEŁ (LAW-MEM-3) — warstwy CZYTANE Z SSOT, nie z hardkodu ───
HOME_DIR="${AIGON_MEMORY_HOME:-${HOME:-/home/sniegul}}"
if [[ -z "${AIGON_MEMORY_HOME:-}" ]]; then
  [ -d "$HOME_DIR/.qwen" ] || HOME_DIR="/home/sniegul"
fi

while IFS=$'\t' read -r kind msg; do
  [ -z "${kind:-}" ] && continue
  case "$kind" in
    PASS) pass "$msg" ;;
    WARN) warn "$msg" ;;
    FAIL) fail "$msg" ;;
    *)    say  "$msg" ;;
  esac
done < <(python3 - "$SSOT" "$HOME_DIR" <<'PY'
import os, socket, subprocess, sys, yaml

ssot, home = sys.argv[1], sys.argv[2]
out = []
try:
    cfg = (yaml.safe_load(open(ssot, encoding="utf-8")) or {}).get("enforcement", {})
except Exception as e:
    print("FAIL\tnie da się odczytać warstw z SSOT (%s)" % e)
    sys.exit(0)

layers = cfg.get("layers") or {}

def emit(kind, msg):
    out.append((kind, msg))

# WARSTWA 1: PAMIĘĆ — indeksy z SSOT
mem = layers.get("memory") or {}
idxs = mem.get("indexes") or []
have, missing = 0, []
for rel in idxs:
    f = os.path.join(home, rel)
    if os.path.isfile(f) and os.path.getsize(f) > 0:
        have += 1
    else:
        missing.append(rel)
if idxs:
    if have:
        emit("PASS", "warstwa PAMIĘĆ żyje: %d/%d indeksów niepustych (%s)" % (have, len(idxs), home))
        if missing:
            emit("WARN", "brakujące indeksy pamięci: %s" % " ".join(missing))
    else:
        emit("FAIL", "warstwa PAMIĘĆ MARTWA: 0/%d indeksów (%s) — prawo wskazuje nieistniejącą pamięć: %s"
             % (len(idxs), home, " ".join(missing)))
else:
    emit("FAIL" if mem.get("required") else "WARN", "SSOT nie deklaruje indeksów pamięci — warstwy 1 nie zmierzono")

# WARSTWA 2: BAZA / REJESTR — kontenery z SSOT
reg = layers.get("registry") or {}
containers = reg.get("containers_any") or []
try:
    subprocess.run(["docker", "info"], stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, timeout=20, check=True)
    ps = subprocess.run(["docker", "ps", "--format", "{{.Names}}"],
                        capture_output=True, text=True, timeout=30)
    if ps.returncode != 0:
        emit("FAIL", "pomiar rejestru docker ps nie powiódł się — częściowy stdout nie jest dowodem życia")
        ps.stdout = ""
    running = [l.strip() for l in (ps.stdout or "").splitlines() if l.strip()]
    alive = [c for c in containers if c in running]
    dead = [c for c in containers if c not in running]
    if containers:
        if alive:
            emit("PASS", "warstwa BAZA/REJESTR żyje: %d/%d rejestrów rdzeniowych UP" % (len(alive), len(containers)))
            if dead:
                emit("WARN", "rejestry rdzeniowe NIE działają: %s" % " ".join(dead))
        else:
            emit("FAIL", "warstwa BAZA/REJESTR MARTWA: 0/%d rejestrów UP — prawo „zajrzyj do bazy” jest wtedy fasadą"
                 % len(containers))
        proj = [n for n in running if n.endswith("-db") or n.endswith("-postgres")]
        emit("PASS", "rejestrów projektowych żywych: %d (warstwa 2 realna, nie tylko rdzeniowa)%s"
             % (len(proj), (": " + ", ".join(sorted(proj)[:6]) + ("…" if len(proj) > 6 else "")) if proj else ""))
    else:
        emit("FAIL" if reg.get("required") else "WARN", "SSOT nie deklaruje kontenerów rejestru — warstwy 2 nie zmierzono")
except Exception:
    emit("WARN", "docker niedostępny z tego kontekstu — warstwy 2 nie zmierzono (brak dostępu != brak bazy)")

# WARSTWA 3: MCP — porty z SSOT
mcp = layers.get("mcp") or {}
ports = mcp.get("ports") or []
up, down = [], []
for p in ports:
    s = socket.socket()
    s.settimeout(1.5)
    try:
        s.connect(("127.0.0.1", int(p)))
        up.append(str(p))
    except Exception:
        down.append(str(p))
    finally:
        s.close()
if ports:
    if up:
        emit("PASS", "warstwa MCP żyje: nasłuchuje :%s (skills_list/knowledge_search/memory_search)" % ", :".join(up))
    if down:
        lvl = "FAIL" if mcp.get("required") else "WARN"
        emit(lvl, "warstwa MCP nie nasłuchuje: :%s" % ", :".join(down))
else:
    emit("WARN", "SSOT nie deklaruje portów MCP — warstwy 3 nie zmierzono")

for k, m in out:
    print("%s\t%s" % (k, m))
PY
LAYER_RC=$?
if [[ "$LAYER_RC" -ne 0 ]]; then
  printf 'FAIL\tkolektor warstw zakończył się błędem (%s) — brak pomiaru nie jest PASS\n' "$LAYER_RC"
fi
)

say "---"
if [ "$FAILS" -gt 0 ]; then
  say "WYNIK: FAIL ($FAILS naruszeń, $WARNS ostrzeżeń) — LAW-MEM-1 nieegzekwowane"
  exit 1
fi
say "WYNIK: PASS (0 naruszeń, $WARNS ostrzeżeń) — LAW-MEM-1 egzekwowane"
exit 0

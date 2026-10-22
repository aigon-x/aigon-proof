#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  tools/gates/mesh-duty.sh — GATE MESH-DUTY (egzekwuje LAW-MESH-1)
#
#  PRAWO (SSOT: config/canonical/mesh-duty.yaml → enforcement):
#    "MESH MA ZAPIERDALAĆ." Cisza nie jest dowodem pracy, a `healthy` na
#    każdym nodzie nie znaczy, że mesh pracuje. Bramka liczbuje W1-W5:
#      W1 DEKOMPOZYCJA  zadanie o strukturze N pozycji → >1 subtask
#      W2 ROZPROSZENIE  subtaski rosną na >1 węźle
#      W3 KERNELE ŻYJĄ  instancje kerneli tykają (na wielu nodach, nie na 1)
#      W4 MASTER DOWODZI scheduler mastera tyka
#      W5 SYNTEZA       wynik wraca jako zebrany artefakt (status done)
#
#  ── [S] SYNTEZA ODCIETA OD OBIETNICY MESHA (2026-09-26) ────────────────────
#  Meshowi wolno obiecywać WYŁĄCZNIE dekompozycję i rozproszenie; dowodem
#  rozproszenia są wyłącznie `subtasks[].node`, NIGDY `remotes=N`. Synteza
#  opisowa NIE JEST obietnicą mesha: worker `qwen2.5-coder:0.5b` robi zadania
#  atomowe i nie niesie syntezy — zmierzone 2× (task 2cb13bf2… subtasks=1 oraz
#  b1926edc… 5 subtasków na 5 RÓŻNYCH nodach; oba `timeout: no result within
#  900s`, synteza ZERO). Syntezę opisową robią subagenci/main model, JAWNIE.
#  Dlatego W5 mierzy NIE „czy mesh obiecał syntezę", tylko „czy praca wróciła
#  jako ZEBRANY ARTEFAKT"; klasa „dekompozycja zaszła, nic nie wróciło" ma
#  teraz własny, falsyfikowalny FAIL na poziomie ZADANIA.
#
#  Zasada pomiaru: brak serii = BRAK (nie zero), brak dowodu = FAIL.
#  Progi i lista zdatnych nodów czytane z SSOT — bramka nie hardkoduje prawa.
#
#  Kontrakt hook-runnera: exit 0 = PASS/WARN, exit 1 = FAIL.
#
#  ── NAPRAWA 2026-09-23 (audyt LAW-MESH: bramka kłamała w OBIE STRONY) ────
#  Trzy defekty zmierzone i zamknięte:
#   [D1] FAŁSZYWY CZERWONY W2 — bramka czytała `aigon_scatter_subtasks_total`
#        i liczyła nody, na których ta seria jest > 0. Ta rodzina to GAUGE
#        LOKALNEGO runtime'u i jej HELP („Suma subtaskow rozproszonych po
#        nodach") KŁAMIE: każdy node eksportuje WŁASNĄ liczbę (master 15,
#        workery 0), więc > 0 ma wyłącznie master. Bramka liczyła zatem
#        „kto WYSŁAŁ subtaski", a nie „na ilu nodach WYKONANO". Zmierzone
#        2026-09-23: master logował `rozklad=[4 różne id×1]`, a bramka
#        orzekała „subtaski tylko na 1 nodach". Teraz W2 czyta ROZKŁAD.
#   [D2] FAŁSZYWY CZERWONY W1/W5 — JSON z mastera był podawany do Pythona
#        przez `printf ... | python3 - <<'PY'`, a heredoc ZJADA stdin
#        (`python3 -` czyta z niego PROGRAM, nie dane). `json.load(sys.stdin)`
#        dostawał EOF, wyjątek szedł w `2>/dev/null` i bramka ZAWSZE orzekała
#        „master widzi 0 zadań" — przy 3 zadaniach widocznych w API (ten sam
#        sekret, HTTP 200). Teraz JSON idzie PLIKIEM przez argv[1].
#   [D3] FAŁSZYWY ZIELONY W1 — SSOT mówi „`subtasks == 1` dla celu
#        wyliczającego pozycje = NARUSZENIE", a implementacja sprawdzała
#        jedynie „n_multi >= 1" (że JAKIEKOLWIEK zadanie jest rozcięte).
#        Cel „Napisz 16 OSOBNYCH funkcji" z subtasks=1 przechodził na zielono.
#        Dodana kontrola wg LITERALNEGO brzmienia SSOT.
#   Do tego [M] — prawo ma wreszcie WŁASNĄ warstwę obserwowalną: rodzina
#        `aigon_mesh_duty_*` (textfile → node_exporter) + span OTLP do Tempo,
#        czyli dokładnie to, co deklaruje prompt SSOT (config/agent-models.yaml,
#        sekcja PRAWO MESHA: „metryki aigon_mesh_duty_*, span OTLP do Tempo").
#        Do 2026-09-23: 0 serii w Prometeuszu, 0 producentów w kodzie,
#        0 spanów w Tempo — warstwa fikcyjna (klasa LAW-011).
#
#  ── [F] W1 MIERZY ŚWIEŻE ZADANIA, NIE ZASZŁOŚCI (2026-09-30, zmierzone) ──
#  ZMIERZONY FAŁSZYWY CZERWONY: bramka czytała CAŁY rejestr mastera (759
#  zadań, 56 h historii, retencja terminalna 604800 s, brak trasy DELETE),
#  a 531 wpisów pochodziło z WYCOFANEGO źródła: `ledger-warden.py` wklejał
#  do `goal` literały metryk („wzrósł do 455.0", „wpis otwarty 6.7h", nazwy
#  projektów z cyfrą). Kontrola [D3] czyta KAŻDĄ liczbę 2..999 jako „cel
#  wyliczający N pozycji", więc bramka raportowała te wpisy jako naruszenia
#  NA PAPIERZE — przy POPRAWNEJ dekompozycji mastera (przejęcie sieroty to
#  zadanie ATOMOWE, `subtasks=1` jest tu poprawne).
#  NAPRAWA: W1 (populacja ORAZ [D3]) liczy wyłącznie zadania z okna
#  `w1_fresh_window_s` z SSOT, po polu `created_at` (epoch s). Okno to samo
#  „fresh", co `aigon_scatter_tasks_failed_fresh` (scripts/state-measure.py,
#  L8) — jedno „fresh" w systemie, nie drugie.
#  TO NIE JEST WYCISZENIE: `subtasks=1` dla celu, który FAKTYCZNIE wylicza
#  N pozycji, W OKNIE nadal jest FAIL-em (dowód: test negatywny,
#  tests/contract/mesh-duty-w1-fresh-window.test.sh). Zaszłość nie może
#  krzyczeć przez tydzień — bieżąca praca musi.
#
#  ZAKRES: bramka NIE zmienia kryteriów W1..W5 poza tym, co konieczne do
#  prawdomówności. Jeżeli werdykt jest CZERWONY z powodu PRAWDZIWEGO
#  (np. realne `subtasks=1` dla celu o N pozycjach) — ma zostać czerwony.
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SSOT="${ROOT}/config/canonical/mesh-duty.yaml"
ENV_FILE="${ROOT}/.env"
PROM="${AIGON_PROM_URL:-http://127.0.0.1:49091}"
OUT_DIR="${AIGON_MESH_DUTY_TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
OUT="${OUT_DIR}/aigon-mesh-duty.prom"
# SPAN OTLP (LAW-MESH-1 „prawo ma zostawić ślad"). NAPRAWA 2026-09-28 —
# ZMIERZONE: default był `http://127.0.0.1:44318`, a kolektor otel słucha
# WYŁĄCZNIE na `100.98.144.70:44318` i tylko po TLS-ie (kanon 2026-09-27,
# świadomie NIE 0.0.0.0; cert z SAN tego IP). Skutek: loopback → HTTP 000,
# czyli span werdyktu NIGDY nie docierał do Tempo — prawo bez świadka
# (dokładnie klasa LAW-011/LAW-OBS-1 opisana w komentarzu wyżej).
# Wartość poniżej to 1:1 default z docker-compose.yml (10 usług ustawia
# AIGON_OTLP_ENDPOINT na ten sam adres) — bierzemy SSOT, nie wymyślamy.
# DOWÓD toru: POST https://100.98.144.70:44318/v1/traces → HTTP 200.
OTLP="${AIGON_OTLP_ENDPOINT:-https://local.aigon.consul:44318}"
# CA kanoniczne dla TLS (curl musi zweryfikować cert; NIE używamy -k).
OTLP_CA="${AIGON_OTLP_CA:-${ROOT}/core/tls/ca-bundle.crt}"
# Fallback do rozkładu z logu mastera — DOMYŚLNIE WYŁĄCZONY. Powód: bramka
# chodzi z crona na local-aigon co 2 min i nie może zależeć od SSH na inny
# node ani od `docker logs` (zmierzone 2026-09-23: 30-60 s). Ustawiony na
# komendę wypisującą linie logu na stdout — wtedy bramka użyje rozkładu 1:1
# z decyzji mastera (dowód mocniejszy niż licznik dispatchu).
LOG_CMD="${AIGON_MESH_DUTY_LOG_CMD:-}"
FAILS=0
WARNS=0
C_W1=""; C_W2=""; C_W3=""; C_W4=""; C_W5=""   # "" = nie zmierzono
NODES_WITH_WORK=""
SUBTASKS_TOTAL=""
# Rozliczenie syntezy na poziomie ZADANIA ([S]). Per-subtask dowod = BRAK
# (master GET /api/v1/tasks/{id} = 404) — publikujemy BRAK/NaN, nigdy 0.
TASKS_DECOMPOSED=""
SUBTASKS_FAILED=""
SUBTASKS_RETURNED=""
N_FAIL_DEC=""

say()  { printf '%s\n' "$*"; }
pass() { say "[PASS] $1"; }
warn() { say "[WARN] $1"; WARNS=$((WARNS+1)); }
fail() { say "[FAIL] $1"; FAILS=$((FAILS+1)); }

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/.mesh-duty.XXXXXX" 2>/dev/null || true)"
if [ -z "$TMPD" ] || [ ! -d "$TMPD" ]; then
  TMPD="/tmp/.mesh-duty.$$"; mkdir -p "$TMPD" 2>/dev/null || true
fi
cleanup() { [ -n "${TMPD:-}" ] && rm -rf "$TMPD" 2>/dev/null; return 0; }
trap cleanup EXIT

say "=== GATE MESH-DUTY (LAW-MESH-1: mesh ma zapierdalać) ==="

# ── 0. SSOT prawa ──────────────────────────────────────────────────────────
if [ -r "$SSOT" ] && grep -q 'LAW-MESH-1' "$SSOT" 2>/dev/null; then
  pass "prawo zadeklarowane w SSOT ($(basename "$SSOT") → LAW-MESH-1)"
else
  fail "brak LAW-MESH-1 w $SSOT — prawo nie istnieje, nie ma czego egzekwować"
fi

# ── Progi z SSOT (nie hardkod) ─────────────────────────────────────────────
# Adres mastera też z SSOT (enforcement.master.api) — adres w kodzie byłby
# drugą kopią prawdy. Override przez AIGON_MESH_DUTY_MASTER_URL dla testu.
# W1_WINDOW_S ([F]): okno świeżości W1 z SSOT — nie hardkod. Override przez
# AIGON_MESH_DUTY_W1_WINDOW_S (tylko do testów granicy okna).
read -r W1_MIN W2_MIN W3_MIN W1_WINDOW_S MASTER_API <<EOF
$(python3 - "$SSOT" <<'PY' 2>/dev/null || echo "2 2 4 3600 https://100.99.59.100:7000"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))["enforcement"]
c = d.get("conditions") or {}
print(c.get("w1_decomposition_min_subtasks", 2),
      c.get("w2_min_nodes_with_subtasks", 2),
      c.get("w3_min_nodes_with_kernel_ticks", 4),
      c.get("w1_fresh_window_s", 3600),
      (d.get("master") or {}).get("api") or "https://100.99.59.100:7000")
PY
)
EOF
W1_MIN="${W1_MIN:-2}"; W2_MIN="${W2_MIN:-2}"; W3_MIN="${W3_MIN:-4}"
W1_WINDOW_S="${AIGON_MESH_DUTY_W1_WINDOW_S:-${W1_WINDOW_S:-3600}}"
MASTER_URL="${AIGON_MESH_DUTY_MASTER_URL:-${MASTER_API:-https://100.99.59.100:7000}}"

# ── Poświadczenie runtime (nigdy nie drukowane) ────────────────────────────
SECRET=""
[ -r "$ENV_FILE" ] && SECRET="$(sed -n 's/^RUNTIME_SHARED_SECRET=//p' "$ENV_FILE" | head -1)"

promq() {  # promq <expr> -> JSON na stdout
  curl -s -m 15 --get "$PROM/api/v1/query" --data-urlencode "query=$1" 2>/dev/null
}
promq_to() {  # promq_to <plik> <expr> — JSON do pliku (parsowanie bez pułapki stdin)
  curl -s -m 15 --get "$PROM/api/v1/query" --data-urlencode "query=$2" -o "$1" 2>/dev/null
}
num_or_nan() { [ -n "${1:-}" ] && printf '%s' "$1" || printf 'NaN'; }

# ══ W1/W5 — dekompozycja i synteza, mierzone u źródła (master API) ═════════
# [D2] JSON idzie PLIKIEM, nie przez `printf | python3 - <<PY` (heredoc zjada
# stdin i bramka czytala EOF — patrz naglowek).
TASKS_FILE="$TMPD/tasks.json"
TASKS_JSON=""
if [ -n "$SECRET" ]; then
  TASKS_JSON="$(curl -sk -m 20 -H "X-API-Key: $SECRET" "${MASTER_URL}/api/v1/tasks" 2>/dev/null)"
fi
printf '%s' "$TASKS_JSON" > "$TASKS_FILE" 2>/dev/null

if [ -z "$TASKS_JSON" ]; then
  fail "W1/W5: brak odpowiedzi mastera ${MASTER_URL}/api/v1/tasks — brak dowodu dekompozycji i syntezy (to NIE jest zero, to brak danych)"
else
  W1_MIN="$W1_MIN" W1_WINDOW_S="$W1_WINDOW_S" python3 - "$TASKS_FILE" > "$TMPD/w1.out" 2>/dev/null <<'PY'
import json, os, re, sys, time
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("UNKNOWN\t?\t?\t?\t?\t?")
    print("NOVIOL\t-\t-\t-\t-")
    raise SystemExit
registry = d.get("scatter_gather") if isinstance(d, dict) else None
if not isinstance(registry, dict) or not isinstance(registry.get("list"), list):
    # HTTP 200 may carry busy/error instead of the task registry.
    print("UNKNOWN\t?\t?\t?\t?\t?")
    print("NOVIOL\t-\t-\t-\t-")
    raise SystemExit
lst = (((d.get("scatter_gather") or {}).get("list")) or [])
w1 = int(os.environ["W1_MIN"])
win = int(os.environ.get("W1_WINDOW_S") or 3600)
if not lst:
    print("BRAK\t0\t0\t0\t0\t?")
    print("NOVIOL\t-\t-\t-\t-")
    raise SystemExit

# ── [F] OKNO ŚWIEŻOŚCI: W1 ocenia BIEŻĄCĄ pracę, nie historię rejestru ───
# Kontrola populacji i kontrola literowa [D3] idą po `fresh`; W5/[S] zostają
# na PEŁNYM rejestrze (kontrakt syntezy NIE jest tu zmieniany — patrz raport).
# Zadanie BEZ `created_at` liczymy jako świeże: brak znacznika nie jest
# dowodem zaszłości, a ukrycie takiego zadania byłoby cichym wyciszeniem.
now = int(time.time())
def _created(t):
    try:
        return int(t.get("created_at") or 0)
    except Exception:
        return 0
fresh = [t for t in lst if _created(t) == 0 or (now - _created(t)) <= win]
n_multi = sum(1 for t in fresh if (t.get("subtasks") or 0) >= w1)
n_done  = sum(1 for t in lst if t.get("status") == "done")
n_fail  = sum(1 for t in lst if t.get("status") == "failed")
subs    = sorted({t.get("subtasks") for t in fresh})
print(f"OK\t{len(fresh)}\t{n_multi}\t{n_done}\t{n_fail}\t{subs}")

# ── [D3] W1 wg LITERALNEGO brzmienia SSOT (na ŚWIEŻYCH zadaniach, [F]) ──
# mesh-duty.yaml: "`subtasks == 1` dla celu wyliczającego pozycje = NARUSZENIE".
# Kontrola jest DODATKOWA (może tylko zaostrzyć: PASS -> FAIL) i celowo
# konserwatywna — heurystyka "cel wylicza N pozycji" ma dwa niezależne
# sygnały, a werdykt wymaga ich ZGODNEGO przekroczenia progu:
#   (1) liczba wprost w treści celu (2..999),
#   (2) liczba pozycji na liście po ostatnim dwukropku.
# Dowód (który sygnał zadziałał + treść celu) idzie do komunikatu, więc
# werdykt jest falsyfikowalny, a nie "bo tak wyszło modelowi".
# [F] Predykat jest BEZ ZMIAN — zmienia się WYŁĄCZNIE populacja, po której
# idzie pętla: `fresh` (okno z SSOT), nie `lst` (cała historia rejestru).
def claimed_positions(goal: str):
    g = goal or ""
    nums = [int(x) for x in re.findall(r"\b(\d{1,4})\b", g)]
    nums = [n for n in nums if 2 <= n <= 999]
    n_num = max(nums) if nums else 0
    tail = g.rsplit(":", 1)[-1] if ":" in g else ""
    parts = [p for p in (s.strip() for s in tail.split(",")) if p]
    n_lst = len(parts) if len(parts) > 1 else 0
    if n_num >= n_lst:
        return n_num, f"liczba wprost={n_num}"
    return n_lst, f"lista {n_lst} pozycji po ':'"

viol = None
for t in fresh:
    sub = t.get("subtasks") or 0
    if sub != 1:
        continue
    n, sig = claimed_positions(t.get("goal") or "")
    if n >= w1:
        viol = (str(t.get("task_id")), sub, n, sig,
                re.sub(r"\s+", " ", str(t.get("goal") or ""))[:120])
        break
if viol:
    print("VIOLATION\t" + "\t".join(str(x) for x in viol))
else:
    print("NOVIOL\t-\t-\t-\t-")

# ── [S] SYNTEZA: czy praca wróciła jako zebrany artefakt (2026-09-26) ────
# Kontrakt kolejności linii w w1.out: OK -> VIOLATION|NOVIOL -> SYNTH.
# Blok MUSI być OSTATNI w tym heredocie — czytnik czyta linie w tej
# kolejności; SYNTH przed [D3] cicho WYŁĄCZA [D3] (V_TAG="SYNTH") i W5.
dec = [t for t in lst if int(t.get("subtasks") or 0) >= w1]
failed_dec = [t for t in dec if t.get("status") == "failed"]
done_dec   = [t for t in dec if t.get("status") == "done"]
subs_failed   = sum(int(t.get("subtasks") or 0) for t in failed_dec)
subs_returned = sum(int(t.get("subtasks") or 0) for t in done_dec)
worst = max(failed_dec, key=lambda t: int(t.get("subtasks") or 0), default=None)
worst_id = str(worst.get("task_id")) if worst else "-"
worst_n  = int(worst.get("subtasks") or 0) if worst else 0
noret = 1 if (dec and not done_dec and failed_dec) else 0
print(f"SYNTH\t{len(dec)}\t{subs_failed}\t{subs_returned}\t{len(failed_dec)}\t{worst_id}\t{worst_n}\t{noret}")
# [F] INFO — linia 4 (kontrakt czyta tylko 3 pierwsze): pełny rejestr vs okno,
# żeby było widać, ILE historii bramka świadomie pomija (nie „ile ukryła").
print(f"INFO\t{len(lst)}\t{len(fresh)}\t{win}")
PY
  { IFS=$'\t' read -r W1_TAG N_TASKS N_MULTI N_DONE N_FAIL W1_SUBS
    IFS=$'\t' read -r V_TAG V_ID V_SUB V_N V_SIG V_EV
    IFS=$'\t' read -r S_TAG N_DEC SUB_FAILED SUB_RETURNED N_FAIL_DEC WORST_ID WORST_N NORET
    IFS=$'\t' read -r I_TAG N_REGISTRY N_FRESH W_WIN
  } < "$TMPD/w1.out"

  if [ "${W1_TAG:-UNKNOWN}" = "UNKNOWN" ]; then
    fail "W1/W5: odpowiedź mastera nie zawiera poprawnego rejestru zadań — pokrycie UNKNOWN (busy/error/niepoprawny JSON), nie zmierzone zero"
  elif [ "${W1_TAG:-BRAK}" = "BRAK" ]; then
    fail "W1/W5: master widzi 0 zadań — nie ma czego mierzyć (cisza != praca, LAW-MESH-2)"
  else
    say "[info] ${I_TAG:-INFO} W1 okno świeżości: ${W_WIN:-${W1_WINDOW_S}} s — rejestr ${N_REGISTRY:-?} zadań, w oknie ${N_FRESH:-?}"
    if [ "${N_TASKS:-0}" -eq 0 ]; then
      # [F] Okno bez świeżej pracy: nie ma CZEGO mierzyć — to nie jest ani
      # dowód dekompozycji, ani dowód jej braku. WARN, a C_W1 zostaje ""
      # (nie zmierzono → NaN w metryce), zgodnie z „brak danych != zero".
      # Uwaga: PUSTY CAŁY rejestr to nadal FAIL (gałąź wyżej) — LAW-MESH-3 żyje.
      warn "W1 dekompozycja: BRAK ŚWIEŻYCH ZADAŃ w oknie ${W_WIN:-${W1_WINDOW_S}} s (rejestr: ${N_REGISTRY:-?}) — nie ma czego mierzyć; to nie jest ani PASS, ani FAIL dekompozycji"
    elif [ "${N_MULTI:-0}" -ge 1 ]; then
      pass "W1 dekompozycja: $N_MULTI/$N_TASKS zadań ŚWIEŻYCH ma >=$W1_MIN subtasków (rozkład subtasków w oknie: ${W1_SUBS:-?})"
    else
      fail "W1 dekompozycja ZŁAMANE: 0/$N_TASKS zadań ŚWIEŻYCH ma >=$W1_MIN subtasków — rozkład subtasków w oknie: ${W1_SUBS:-?} (dekompozycja nie tnie pracy)"
    fi
    # [D3] kontrola wg literatury SSOT (dodatkowa, nie zastępuje powyższej).
    # [F] Pętla idzie po ŚWIEŻYCH zadaniach (fresh), więc komunikat podaje okno.
    if [ "${V_TAG:-NOVIOL}" = "VIOLATION" ]; then
      fail "W1 dekompozycja ZŁAMANE wg SSOT: task ${V_ID} → subtasks=${V_SUB} dla celu o N=${V_N} pozycji [${V_SIG}] — \"${V_EV}\" (SSOT: subtasks==1 dla celu wyliczającego pozycje = NARUSZENIE; okno świeżości ${W_WIN:-${W1_WINDOW_S}} s, created_at w oknie)"
    fi
    if [ "${N_DONE:-0}" -ge 1 ]; then
      pass "W5 synteza: $N_DONE zadań domkniętych (done)"
    else
      fail "W5 synteza ZŁAMANE: 0 done, ${N_FAIL:-0} failed — praca nie wraca jako zebrany artefakt"
    fi
    # warunki do metryki (prawdomówne, nie przybliżone). [F] Gdy w oknie nie ma
    # ŚWIEŻEJ pracy, C_W1 zostaje "" (nie zmierzono → NaN) — nie udajemy złamania.
    if [ "${N_TASKS:-0}" -gt 0 ]; then
      [ "${N_MULTI:-0}" -ge 1 ] && [ "${V_TAG:-NOVIOL}" != "VIOLATION" ] && C_W1=1 || C_W1=0
    fi
    [ "${N_DONE:-0}" -ge 1 ] && C_W5=1 || C_W5=0
    # ── W5 TWARDY POMIAR ARTEFAKTU (2026-09-30) ───────────────────────────
    # DOTAD W5 = "jest >=1 done" (STATUS). Zmierzone: zadanie `85b3d9e0` bylo
    # done bez artefaktu syntezy i przechodzilo. TERAZ pytamy mastera o KONKRETNE
    # zadanie i sprawdzamy `synthesis_present` — logika pomiaru w osobnym
    # skrypcie (mesh-duty-w5.py), bramka tylko tlumaczy werdykt. Brak pola
    # (starszy runtime) = NODATA = nie zmieniamy werdyktu (brak danych != zero).
    if [ -n "${SECRET:-}" ] && [ -n "${WORST_ID:-}" ] && [ "${N_DONE:-0}" -ge 1 ]; then
      _w5one="$TMPD/w5_status.json"
      curl -sk -m 15 -H "X-API-Key: $SECRET" "${MASTER_URL}/api/v1/tasks/${WORST_ID}/status" > "$_w5one" 2>/dev/null || true
      _w5v="$(python3 "$ROOT/tools/gates/mesh-duty-w5.py" "$_w5one" 2>/dev/null || echo NODATA)"
      if [ "$_w5v" = "MISSING" ]; then
        fail "W5 SYNTEZA ZLAMANE (twardy pomiar): zadanie ${WORST_ID} jest 'done', ale BRAK artefaktu (synthesis_present=false, synthesis_started=false). LAW-MESH-1 W5 wymaga artefaktu, nie samego statusu."
        C_W5=0
      elif [ "$_w5v" = "OK" ]; then
        say "[info] W5 dowod artefaktu: zadanie ${WORST_ID} done + synthesis_present=true"
      elif [ "$_w5v" = "INPROGRESS" ]; then
        say "[info] W5 synteza w toku: zadanie ${WORST_ID} (synthesis_started=true, artefakt jeszcze nie zapisany)"
      fi
    fi
    if [ "${S_TAG:-BRAK}" = "SYNTH" ]; then
      TASKS_DECOMPOSED="$N_DEC"; SUBTASKS_FAILED="$SUB_FAILED"
      SUBTASKS_RETURNED="$SUB_RETURNED"; N_FAIL_DEC="$N_FAIL_DEC"
      if [ "${SUB_RETURNED:-0}" -eq 0 ] && [ "${N_DEC:-0}" -ge 1 ] && [ "${N_FAIL_DEC:-0}" -ge 1 ]; then
        fail "W5 SYNTEZA NIE WROCIŁA: ${N_DEC} zadań zdekomponowanych, ${SUB_FAILED} subtasków rozdysponowanych, 0 wróciło — ${N_FAIL_DEC} zadań zdekomponowanych padło (np. task ${WORST_ID} — ${WORST_N} subtasków). Rozproszenie zaszło, synteza nie: praca wyrzucona. Per-subtask dowód: BRAK (master GET /api/v1/tasks/{id} = 404 — brak danych != zero, LAW-MESH-2)."
        C_W5=0
      fi
    fi
  fi
fi

# ══ W2 — ROZPROSZENIE: na ilu RÓŻNYCH nodach WYKONANO pracę ════════════════
# [D1] Źródłem werdyktu jest ROZKŁAD, a NIE:
#   - `aigon_scatter_subtasks_total` (lokalny gauge runtime'u — master 15,
#     workery 0; to była przyczyna fałszywego czerwonego), ani
#   - `remotes=N` (kanon: lista KANDYDATÓW do alokacji, nie dowód wykonania).
#  (A) `aigon_tasks_dispatched_total` — eksportowany przez /metrics KAŻDEGO
#      runtime'u (job="aigon-runtime"). Label `exported_node` = WŁASNE
#      mesh.node_id tego runtime'u — TA SAMA przestrzeń id, co `rozklad=[id×ile]`
#      w logu mastera. Wartość = kpi.total_tasks_assigned, rośnie przy
#      FAKTYCZNYM dispatchu (api.rs:6564 — remote send_task + lokalny fallback).
#      Okno 15 min: spójne z ln.py `L8_tasks.worker_nodes_with_assignment`.
#  (B) FALLBACK (env AIGON_MESH_DUTY_LOG_CMD): linie
#      `[SCATTER-GATHER] remotes=N rozklad=[id×ile]` z logu mastera — liczymy
#      UNIKALNE id z `rozklad` (1:1 z decyzją mastera, mocniejszy dowód).
promq_to "$TMPD/w2.json" 'max_over_time(aigon_tasks_dispatched_total[15m]) > 0'
W2_PROM_N=""; W2_PROM_SUM=""; W2_PROM_LIST=""
if [ -s "$TMPD/w2.json" ]; then
  python3 - "$TMPD/w2.json" > "$TMPD/w2.out" 2>/dev/null <<'PY'
import json, sys
try:
    rs = json.load(open(sys.argv[1]))["data"]["result"]
except Exception:
    raise SystemExit          # brak parsowania = pomiar nieudany (puste wyjscie)
if not rs:
    print("0\t0\t-"); raise SystemExit
pairs = []
for s in rs:
    pairs.append((s["metric"].get("node") or "?",
                  s["metric"].get("exported_node") or "-",
                  float(s["value"][1])))
pairs.sort()
print(f"{len(pairs)}\t{sum(p[2] for p in pairs)}\t" +
      ",".join(f"{n}({e}={v:.0f})" for n, e, v in pairs))
PY
  IFS=$'\t' read -r W2_PROM_N W2_PROM_SUM W2_PROM_LIST < "$TMPD/w2.out"
fi

W2_LOG_N=""; W2_LOG_DESC=""
if [ -n "$LOG_CMD" ]; then
  # UWAGA (zmierzone 2026-09-23): kod wyjścia komendy logu NIE jest dowodem
  # awarii — `grep` bez dopasowań zwraca 1, a to jest ODPOWIEDŹ („brak linii
  # rozklad= w tym oknie"), nie porażka. Dlatego rozstrzyga OBECNOŚĆ DANYCH:
  # plik z treścią → parsujemy (nawet przy rc!=0); brak treści → fallback
  # nieużyty, a rc tylko opisuje, czym to zostało wywołane.
  log_rc=0
  bash -c "$LOG_CMD" > "$TMPD/master.log" 2>/dev/null || log_rc=$?
  if [ -s "$TMPD/master.log" ]; then
    python3 - "$TMPD/master.log" > "$TMPD/w2log.out" 2>/dev/null <<'PY'
import re, sys
ids = set(); lines = 0
for line in open(sys.argv[1], errors="replace"):
    m = re.search(r"rozklad=\[([^\]]*)\]", line)
    if not m:
        continue
    lines += 1
    for part in m.group(1).split(","):
        nid = re.split(r"[×x]", part)[0].strip()
        if nid:
            ids.add(nid)
if lines:
    print(f"{len(ids)}\trozklad=[{lines} linii logu, {len(ids)} unikalnych node_id]")
PY
    IFS=$'\t' read -r W2_LOG_N W2_LOG_DESC < "$TMPD/w2log.out"
  fi
  if [ -z "$W2_LOG_N" ]; then
    if [ "$log_rc" -ne 0 ]; then
      warn "W2: komenda logu nie zwróciła ŻADNYCH danych (rc=${log_rc}) — fallback pominięty, źródłem werdyktu zostaje licznik dispatchu"
    else
      warn "W2: log mastera bez linii 'rozklad=' w oknie komendy — fallback nieużyty, źródłem werdyktu zostaje licznik dispatchu"
    fi
  fi
fi

W2_N=""; W2_SRC=""
if [ -n "$W2_LOG_N" ]; then
  W2_N="$W2_LOG_N"; W2_SRC="log mastera ($W2_LOG_DESC)"
  if [ -n "$W2_PROM_N" ] && [ "$W2_PROM_N" != "$W2_LOG_N" ]; then
    warn "W2: ROZJAZD ŹRÓDEŁ — rozkład z logu mastera=$W2_LOG_N nodów, licznik dispatchu=$W2_PROM_N nodów [$W2_PROM_LIST]. Werdykt idzie na NIŻSZĄ wartość (bramka nie zielenieje na słabszym dowodzie), a sam rozjazd jest sygnałem, nie szumem."
    if [ "$W2_PROM_N" -lt "$W2_LOG_N" ]; then
      W2_N="$W2_PROM_N"; W2_SRC="licznik dispatchu (niższa z dwóch; log mastera=$W2_LOG_N)"
    fi
  fi
elif [ -n "$W2_PROM_N" ]; then
  W2_N="$W2_PROM_N"; W2_SRC="aigon_tasks_dispatched_total (okno 15m, eksport runtime'u)"
fi

if [ -z "$W2_N" ]; then
  fail "W2: brak dowodu rozproszenia — ani Prometheus (aigon_tasks_dispatched_total), ani log mastera nie odpowiedziały"
elif [ "$W2_N" -ge "$W2_MIN" ]; then
  pass "W2 rozproszenie: $W2_N RÓŻNYCH nodów miało pracę (próg $W2_MIN) — źródło: $W2_SRC"
  C_W2=1
else
  fail "W2 rozproszenie ZŁAMANE: praca tylko na $W2_N nodzie/nodach (próg $W2_MIN) — źródło: $W2_SRC"
  C_W2=0
fi
if [ -n "$W2_PROM_LIST" ]; then
  say "[info] W2 rozkład pracy per node (IP(exported_node=wartość)): $W2_PROM_LIST"
fi
if [ -n "$W2_LOG_DESC" ]; then
  say "[info] W2 $W2_LOG_DESC"
fi
NODES_WITH_WORK="$W2_N"
SUBTASKS_TOTAL="$W2_PROM_SUM"

# ══ W3 — kernele tykają (nie tylko na localu) ══════════════════════════════
W3_JSON="$(promq 'aigon_kernel_ticks_total > 0')"
W3_N="$(printf '%s' "$W3_JSON" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)["data"]["result"]
    print(len({s["metric"].get("node") for s in d if s["metric"].get("node")}))
except Exception: print("")
' 2>/dev/null)"
if [ -z "$W3_N" ]; then
  fail "W3: brak odpowiedzi Prometheusa na aigon_kernel_ticks_total — brak dowodu, nie „kernele OK”"
elif [ "$W3_N" -ge "$W3_MIN" ]; then
  pass "W3 kernele: tykają na $W3_N nodach (próg $W3_MIN)"
  C_W3=1
else
  fail "W3 kernele ZŁAMANE: tykają tylko na $W3_N nodach (próg $W3_MIN) — mesh nie liczy równolegle"
  C_W3=0
fi

# ══ W4 — master dowodzi ════════════════════════════════════════════════════
W4_JSON="$(promq 'aigon_kpi_scheduler_ticks_total')"
if [ -z "$W4_JSON" ]; then
  fail "W4: brak odpowiedzi Prometheusa na aigon_kpi_scheduler_ticks_total — brak dowodu, kto dowodzi"
else
  printf '%s' "$W4_JSON" | python3 -c '
import json,sys
try:
    rs=json.load(sys.stdin)["data"]["result"]
except Exception:
    print("BRAK\t0"); raise SystemExit
leader=None; best=0
for s in rs:
    v=float(s["value"][1]); n=s["metric"].get("node","?")
    if v>best: best, leader = v, n
print(f"LEADER\t{leader}\t{best}")
' 2>/dev/null > "$TMPD/w4.out"
  W4_LINE="$(cat "$TMPD/w4.out" 2>/dev/null)"
  IFS=$'\t' read -r W4_TAG W4_NODE W4_VAL <<<"${W4_LINE:-BRAK}"
  if [ "${W4_TAG:-BRAK}" = "BRAK" ]; then
    fail "W4: brak serii aigon_kpi_scheduler_ticks_total — nie wiadomo, czy master dowodzi"
  elif python3 -c "import sys; sys.exit(0 if float('${W4_VAL:-0}') > 0 else 1)"; then
    if [ "${W4_NODE}" = "100.99.59.100" ]; then
      pass "W4 master dowodzi: scheduler tyka na masterze (${W4_NODE}, ${W4_VAL} ticków)"
      C_W4=1
    else
      warn "W4: scheduler tyka najwyżej na ${W4_NODE}, a master to 100.99.59.100 — sprawdź przywództwo"
      C_W4=0
    fi
  else
    fail "W4 master NIE dowodzi: aigon_kpi_scheduler_ticks_total = 0 — nikt nie prowadzi dekompozycji i przydziału"
    C_W4=0
  fi
fi

# ══ METRYKI PRAWA (aigon_mesh_duty_*) + SPAN OTLP (Tempo) ══════════════════
# [M] Warstwa obserwowalna, którą kanon JUŻ przypisuje temu prawu (prompt SSOT,
# sekcja PRAWO MESHA: „metryki aigon_mesh_duty_*, span OTLP do Tempo"), a która
# do 2026-09-23 nie istniała (0 serii / 0 producentów / 0 spanów = LAW-011).
# Zapis ATOMOWY (mktemp + mv), wzorzec: scripts/aigon-scatter-lane-exporter.sh.
# BRAK POMIARU != ZERO: niezmierzona wartość idzie jako NaN (seria JEST, ale nie
# udaje liczby), a `export_ok` = 0 — ratchet rodzin nic nie traci, a reguły
# porównawcze (`== 0`, `< próg`) nie zapalają się od braku danych (LAW-MESH-2).
NOW_TS="$(date +%s)"

# ── W6 (2026-10-01, ROZKAZ SUWERENA — ZBETONOWANE) ─────────────────────────
# PRZECIĄŻENIE WĘZŁA NIGDY NIE JEST USPRAWIEDLIWIENIEM PADNIĘTEGO SUBTASKA.
# load1 >= liczba rdzeni na węźle = węzeł NIEKWALIFIKOWALNY; wysłanie tam
# subtaska to NARUSZENIE (runtime miał to wykryć, nie przepuścić).
# DOWÓD ZMIERZONY 2026-10-01: contabo load 36.31/37.36/36.85 na 12 rdzeniach;
# curl :11435 (brama CPU) i :11445 (CPU ollama) -> HTTP=000 po 40-45 s (WISI);
# brama: 'KOLEJKA PELNA (4) — 503 queue_rejected=5564'; 0/7 subtasków wykonanych.
# SSOT: config/canonical/mesh-duty.yaml → enforcement.conditions.w6_enabled.
W6_ENABLED="$(python3 -c 'import sys,yaml;d=yaml.safe_load(open(sys.argv[1]))["enforcement"]["conditions"];print(1 if d.get("w6_enabled") else 0)' "$SSOT" 2>/dev/null || echo 1)"
C_W6=""
if [ "$W6_ENABLED" = "1" ]; then
  W6_JSON="$(promq 'node_load1 / on(instance) group_left() count by (instance) (node_cpu_seconds_total{mode="idle"}) > 1' 2>/dev/null)"
  W6_N="$(printf '%s' "$W6_JSON" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(len(d.get("data",{}).get("result",[])))' 2>/dev/null || echo "")"
  if [ -n "$W6_N" ]; then
    if [ "$W6_N" -gt 0 ]; then
      C_W6=0
      say "[FAIL] W6 przeciążenie: ${W6_N} węzłów z load1 >= rdzenie — wysłanie tam subtaska = NARUSZENIE (admission control + kaskada zewnętrzna OBOWIĄZKOWE)"
      FAILS=$((FAILS+1))
    else
      C_W6=1
      say "[PASS] W6 brak węzłów przeciążonych (load1 < rdzenie na wszystkich)"
    fi
  else
    say "[WARN] W6 nie zmierzono (brak node_load1/node_cpu_seconds_total) — brak pomiaru != brak naruszenia"
    WARNS=$((WARNS+1))
  fi
fi

export_ok=1
[ -z "$C_W1" ] && export_ok=0
[ -z "$C_W2" ] && export_ok=0
[ -z "$C_W3" ] && export_ok=0
[ -z "$C_W4" ] && export_ok=0
[ -z "$C_W5" ] && export_ok=0
[ -z "$C_W6" ] && export_ok=0
if [ "$FAILS" -gt 0 ]; then duty_ok=0; else duty_ok=1; fi

# Rozliczenie syntezy ([S]) jako warunki do metryki i do spanu. SYNTH_MISS=1 gdy
# dekompozycja zaszla, a synteza nie wrocila (subtasks rozdzielone, 0 wrocilo).
SYNTH_RET="$(num_or_nan "$SUBTASKS_RETURNED")"
SYNTH_MISS=""
if [ -n "$TASKS_DECOMPOSED" ] && [ "${SUBTASKS_RETURNED:-0}" -eq 0 ]; then SYNTH_MISS=1; fi

mkdir -p "$OUT_DIR" 2>/dev/null
tmp_prom="$(mktemp "${OUT_DIR}/.aigon-mesh-duty.XXXXXX" 2>/dev/null)" || tmp_prom=""
if [ -n "$tmp_prom" ]; then
  {
    echo "# HELP aigon_mesh_duty_ok 1 gdy warunki W1..W5 wszystkie przeszly (0 gdy ktorykolwiek zlamany)"
    echo "# TYPE aigon_mesh_duty_ok gauge"
    echo "aigon_mesh_duty_ok ${duty_ok}"
    echo "# HELP aigon_mesh_duty_nodes_with_work Liczba ROZNYCH nodow, na ktorych wykonano rozlozona prace (rozkład z aigon_tasks_dispatched_total lub logu mastera; NIE z remotes=N)"
    echo "# TYPE aigon_mesh_duty_nodes_with_work gauge"
    echo "aigon_mesh_duty_nodes_with_work $(num_or_nan "$NODES_WITH_WORK")"
    echo "# HELP aigon_mesh_duty_subtasks_total Suma subtaskow rozlozonych po nodach (suma dispatchu per node, okno 15m)"
    echo "# TYPE aigon_mesh_duty_subtasks_total gauge"
    echo "aigon_mesh_duty_subtasks_total $(num_or_nan "$SUBTASKS_TOTAL")"
    echo "# HELP aigon_mesh_duty_tasks_decomposed Liczba zadan z subtasks >= prog W1 (dekompozycja realnie zaszla; NaN = nie zmierzono)"
    echo "# TYPE aigon_mesh_duty_tasks_decomposed gauge"
    echo "aigon_mesh_duty_tasks_decomposed $(num_or_nan "$TASKS_DECOMPOSED")"
    echo "# HELP aigon_mesh_duty_subtasks_returned Suma subtaskow zadan zdekomponowanych, ktore wrocily jako done (0 = synteza nie wrocila)"
    echo "# TYPE aigon_mesh_duty_subtasks_returned gauge"
    echo "aigon_mesh_duty_subtasks_returned $(num_or_nan "$SUBTASKS_RETURNED")"
    echo "# HELP aigon_mesh_duty_subtasks_failed Suma subtaskow zadan zdekomponowanych, ktore padly (failed) — praca wyrzucona"
    echo "# TYPE aigon_mesh_duty_subtasks_failed gauge"
    echo "aigon_mesh_duty_subtasks_failed $(num_or_nan "$SUBTASKS_FAILED")"
    echo "# HELP aigon_mesh_duty_last_run_timestamp_seconds Czas ostatniego przebiegu bramki LAW-MESH-1 (epoch)"
    echo "# TYPE aigon_mesh_duty_last_run_timestamp_seconds gauge"
    echo "aigon_mesh_duty_last_run_timestamp_seconds ${NOW_TS}"
    echo "# HELP aigon_mesh_duty_export_ok 1 gdy wszystkie zrodla pomiaru odpowiedzialy (0 = pomiar niepelny, fail-visible)"
    echo "# TYPE aigon_mesh_duty_export_ok gauge"
    echo "aigon_mesh_duty_export_ok ${export_ok}"
    echo "# HELP aigon_mesh_duty_condition_ok Warunek prawa W1..W5 (1 ok, 0 zlamany, NaN nie zmierzono)"
    echo "# TYPE aigon_mesh_duty_condition_ok gauge"
    for c in w1 w2 w3 w4 w5 w6; do
      case "$c" in
        w1) v="$C_W1";; w2) v="$C_W2";; w3) v="$C_W3";; w4) v="$C_W4";; w5) v="$C_W5";; w6) v="$C_W6";;
      esac
      echo "aigon_mesh_duty_condition_ok{condition=\"${c}\"} $(num_or_nan "$v")"
    done
  } > "$tmp_prom" 2>/dev/null
  chmod 644 "$tmp_prom" 2>/dev/null
  if mv -f "$tmp_prom" "$OUT" 2>/dev/null; then
    say "[info] metryki prawa: $OUT (ok=${duty_ok} export_ok=${export_ok})"
  else
    say "[WARN] nie udało się opublikować $OUT — warstwa metryk prawa NIE działa"
  fi
else
  say "[WARN] brak zapisywalnego katalogu na textfile ($OUT_DIR) — warstwa metryk prawa NIE opublikowana"
fi

if [ -n "$OTLP" ]; then
  payload="$(NOW_NS="$(date +%s%N)" TRACE="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')" \
    OK="$duty_ok" EXPORT_OK="$export_ok" FAILS="$FAILS" WARNS="$WARNS" \
    NW="$NODES_WITH_WORK" ST="$SUBTASKS_TOTAL" \
    TD="$TASKS_DECOMPOSED" SR="$SUBTASKS_RETURNED" SRET="$SYNTH_RET" SMISS="$SYNTH_MISS" python3 -c '
import json, os, time
ns = int(os.environ.get("NOW_NS") or time.time_ns())
tid = (os.environ.get("TRACE") or "0"*32)[:32].ljust(32, "0")
def i(k):
    try: return int(float(os.environ.get(k) or 0))
    except Exception: return 0
attrs = [
  {"key": "ok",              "value": {"intValue": i("OK")}},
  {"key": "export_ok",       "value": {"intValue": i("EXPORT_OK")}},
  {"key": "fails",           "value": {"intValue": i("FAILS")}},
  {"key": "warns",           "value": {"intValue": i("WARNS")}},
  {"key": "nodes_with_work", "value": {"intValue": i("NW")}},
  {"key": "subtasks_total",  "value": {"intValue": i("ST")}},
  {"key": "tasks_decomposed",   "value": {"intValue": i("TD")}},
  {"key": "subtasks_returned",  "value": {"intValue": i("SR")}},
  {"key": "synthesis_returned", "value": {"intValue": i("SRET")}},
  {"key": "synthesis_missing",  "value": {"intValue": i("SMISS")}},
  {"key": "law",             "value": {"stringValue": "LAW-MESH-1"}},
]
span = {"traceId": tid, "spanId": tid[:16], "name": "mesh.duty.verdict",
        "kind": 3, "startTimeUnixNano": str(ns), "endTimeUnixNano": str(ns + 1000000),
        "attributes": attrs}
out = {"resourceSpans": [{"resource": {"attributes": [
          {"key": "service.name", "value": {"stringValue": "mesh-duty-gate"}}]},
        "scopeSpans": [{"scope": {"name": "aigon.mesh-duty"}, "spans": [span]}]}]}
print(json.dumps(out))' 2>/dev/null)"
  if [ -n "$payload" ]; then
    # --cacert tylko gdy CA istnieje (TLS z Core CA); brak -k — nie obchodzimy
    # weryfikacji certu, tylko podajemy kanoniczne zaufanie.
    ca_arg=""; [ -f "$OTLP_CA" ] && ca_arg="--cacert ${OTLP_CA}"
    # shellcheck disable=SC2086
    otlp_code="$(curl -s -m 10 -o /dev/null -w '%{http_code}' $ca_arg -X POST \
      -H 'Content-Type: application/json' -d "$payload" "${OTLP}/v1/traces" 2>/dev/null || echo 000)"
    say "[info] span OTLP mesh.duty.verdict → ${OTLP} (HTTP=${otlp_code})"
  fi
fi

# ══ Podsumowanie ═══════════════════════════════════════════════════════════
say "---"
if [ "$FAILS" -gt 0 ]; then
  say "WYNIK: FAIL ($FAILS naruszeń, $WARNS ostrzeżeń) — MESH NIE ZAPIERDALA (LAW-MESH-1 złamane)"
  exit 1
fi
say "WYNIK: PASS (0 naruszeń, $WARNS ostrzeżeń) — mesh zapierdala"
exit 0

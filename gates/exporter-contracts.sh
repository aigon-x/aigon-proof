#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  tools/gates/exporter-contracts.sh — KONTRAKTY PRODUCENTÓW TELEMETRII
#
#  PO CO (zmierzone 2026-09-23): tego dnia znaleziono SZEŚĆ defektów tej samej
#  rodziny — producent metryki, który MIERZY ŹLE, więc jego zielone światło
#  jest fałszywe, a awaria niewidoczna. Każdy był naprawiony, ale NIC nie
#  broniło naprawy przed cichym cofnięciem przy następnej edycji:
#
#    1. `aigon-ollama-spin-guard.sh` — okno 10 s + brak dowodu pracy na slotach
#       ⇒ guard uznawał spin W ŚRODKU generacji i RESTARTOWAŁ ollamę w trakcie
#       pracy (wszystkie subtaski scattera: `curl exit 28`).
#    2. `aigon-mcp-exporter.sh` — sondował `:7000/mcp`, które NIE ISTNIEJE
#       (404) ⇒ fałszywe „runtime-mcp down”; brak fallbacku `cwd` (6 serwerów
#       fałszywie down); shimom wysyłał dwa żądania zamiast jednego.
#    3. `aigon-mesh-nodes-exporter.sh` — `node_up` bezwarunkowo 1 dla wpisu
#       w API ⇒ węzły martwe od tygodni świeciły się jako „up".
#    4. `aigon-mail-exporter.py` — seria `aigon_mail_out_total` tylko dla
#       zaobserwowanych kombinacji ⇒ w ciszy NIE ISTNIAŁA, a 2 reguły mailowe
#       nie mogły się zapalić.
#    5. `scripts/state-ratchet-exporter.sh` — ratchet bez telemetrii (naprawione).
#    6. Cron: wpis w SSOT != żywy plik (SSOT edytowany, `/etc/cron.d` nie).
#
#  Ten gejt czyta ŹRÓDŁA producentów i wymaga, żeby te inwarianty były w nich
#  OBECNE, oraz żeby każdy producent był wpięty w SSOT cronu I w żywy plik.
#  Klasa „producent bez kontraktu" jest wtedy widoczna w CI, a nie dopiero przy
#  awarii.
#
#  Kontrakt: exit 0 = PASS · 1 = FAIL (kontrakt złamany) · 3 = WARN (brak
#  dostępu do żywego cronu/textfile — narzędzie niedostępne != awaria).
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CRON_SSOT="${ROOT}/config/cron.yaml"
CRON_LIVE="/etc/cron.d/aigon-cron"
TEXTFILE="/var/lib/node_exporter/textfile_collector"

PASS=0; FAIL=0; WARN=0
ok()   { echo "[PASS] $*"; PASS=$((PASS+1)); }
bad()  { echo "[FAIL] $*"; FAIL=$((FAIL+1)); }
warn() { echo "[WARN] $*"; WARN=$((WARN+1)); }

# ── Pomocnicze: czy plik zawiera wzorzec ─────────────────────────────────
has() { grep -qE "$2" "$1" 2>/dev/null; }

echo "=== KONTRAKTY PRODUCENTÓW TELEMETRII ==="

# ── 1. SPIN-GUARD: okno dłuższe niż generacja + dowód pracy na slotach ───
SG="${ROOT}/scripts/aigon-ollama-spin-guard.sh"
if [ ! -f "$SG" ]; then
  bad "EXPC-001 brak ${SG} — producent metryki spinu zniknął"
else
  # WINDOW musi mieć domyślną wartość >= 120 s (jedno żądanie generuje 30-120 s;
  # przy krótszym oknie „brak startów żądań" jest mylone ze spinem).
  _w="$(grep -oE 'AIGON_OLLAMA_GUARD_WINDOW:-[0-9]+' "$SG" | head -1 | grep -oE '[0-9]+$')"
  if [ -n "$_w" ] && [ "$_w" -ge 120 ]; then
    ok "EXPC-001 spin-guard: okno domyślne ${_w}s (>=120) — nie myli generacji ze spinem"
  else
    bad "EXPC-001 spin-guard: okno domyślne '${_w:-brak}' < 120s — wróci fałszywy spin i restart w trakcie pracy (curl exit 28)"
  fi
  # Drugi, niezależny dowód pracy: aktywność slotów.
  if has "$SG" 'BUSY_SLOTS' && has "$SG" 'slot \.\*task'; then
    ok "EXPC-002 spin-guard: liczy BUSY_SLOTS (aktywność slotów), nie tylko starty żądań"
  else
    bad "EXPC-002 spin-guard: brak dowodu pracy na slotach — CPU wysokie w trakcie generacji znów zostanie uznane za SPIN"
  fi
  # Restart tylko przy braku OBU dowodów.
  if has "$SG" 'BUSY_SLOTS" -eq 0 \] && SPIN=1|BUSY_SLOTS" -eq 0.*SPIN=1'; then
    ok "EXPC-003 spin-guard: restart warunkowany brakiem żądań ORAZ brakiem aktywności slotów"
  else
    bad "EXPC-003 spin-guard: restart nie jest warunkowany brakiem obu dowodów pracy"
  fi
fi

# ── 2. MCP: nie sondować nieistniejącej trasy, mieć fallback cwd + shim ───
MX="${ROOT}/scripts/aigon-mcp-exporter.sh"
if [ ! -f "$MX" ]; then
  bad "EXPC-004 brak ${MX} — ścieżka krytyczna agentów (brama/gateway/runtime MCP) bez telemetrii"
else
  # UWAGA (zmierzone 2026-09-23): pierwsza wersja tego testu była `grep` po
  # CAŁYM pliku i dała FAŁSZYWE FAIL — trafiała we WŁASNY KOMENTARZ, w którym
  # wyjaśniam usunięcie tej trasy. To klasa „fałszywa kontrola: grep po wzorcu
  # zamiast odczytu struktury". Dlatego komentarze są odfiltrowane: liczy się
  # WYŁĄCZNIE kod (aktywna sonda), nie wzmianka w opisie.
  if grep -vE '^[[:space:]]*#' "$MX" | grep -q '7000/mcp'; then
    bad "EXPC-004 mcp-exporter: sondowana trasa :7000/mcp NIE ISTNIEJE (404) — to był fałszywy czerwony 'runtime-mcp down'"
  else
    ok "EXPC-004 mcp-exporter: nie sonduje nieistniejącej trasy :7000/mcp (kod; komentarze nie liczą się)"
  fi
  if has "$MX" 'run_cwd' && has "$MX" 'os\.path\.isdir'; then
    ok "EXPC-005 mcp-exporter: ma fallback cwd (reguła runtime api.rs:10046) — bez tego 6 serwerów fałszywie down"
  else
    bad "EXPC-005 mcp-exporter: brak fallbacku cwd — seria 'config ma /app' znów da fałszywe down"
  fi
  if has "$MX" 'mcp_stdio_shim\.py' && has "$MX" 'is_shim'; then
    ok "EXPC-006 mcp-exporter: rozpoznaje shim (jedno żądanie na stdin)"
  else
    bad "EXPC-006 mcp-exporter: brak obsługi shimu — fetch/crawl4ai znów 'initialize ok, brak tools/list'"
  fi
fi

# ── 3. MESH: node_up musi honorować świeżość ─────────────────────────────
MN="${ROOT}/scripts/aigon-mesh-nodes-exporter.sh"
if [ ! -f "$MN" ]; then
  bad "EXPC-007 brak ${MN}"
else
  if has "$MN" 'reachable = 1 if \(stale == 0'; then
    ok "EXPC-007 mesh-exporter: node_up honoruje świeżość (martwy wpis != up)"
  else
    bad "EXPC-007 mesh-exporter: node_up bez warunku świeżości — węzły martwe od tygodni znów będą 'up'"
  fi
fi

# ── 4. MAIL: kanoniczne serie zawsze obecne ──────────────────────────────
ME="${ROOT}/scripts/aigon-mail-exporter.py"
if [ ! -f "$ME" ]; then
  bad "EXPC-008 brak ${ME}"
else
  if has "$ME" '_seeded' ; then
    ok "EXPC-008 mail-exporter: kanoniczne serie (blocked/deferred/bounced @gmail) zawsze obecne — reguły nie są martwe w ciszy"
  else
    bad "EXPC-008 mail-exporter: serie tylko dla zaobserwowanych kombinacji — reguły MailRelayRejectingGmail/MailContentBlocked znów martwe bez ruchu"
  fi
fi

# ── 5. Ratchet: producent telemetrii ratchetu istnieje ───────────────────
SR="${ROOT}/scripts/state-ratchet-exporter.sh"
if [ -f "$SR" ]; then ok "EXPC-009 producent telemetrii ratchetu istnieje"; else bad "EXPC-009 brak ${SR} — ratchet znów bez metryki i spanu"; fi

# ── 5b. Producent metryk: plik MUSI leżeć w KATALOGU ZBIERANYM i być czytelny ──
# Zmierzone 2026-10-14 (dwie awarie tej samej klasy):
#   * notify-gateway.py pisał metryki do /var/lib/aigon/ — node_exporter czyta
#     wyłącznie /var/lib/node_exporter/textfile_collector, więc droga alertu
#     była NIEWIDOCZNA mimo licznika 132 błędów wysyłki,
#   * eksportery piszące przez `mktemp` (0600) bez `chmod 0644` — plik istnieje,
#     a `nobody` go nie odczyta (aigon-szpieg.prom, monai_bet.prom).
# Ten test czyta DEKLARACJĘ ze SSOT i wymaga, żeby wskazywała katalog zbierany.
TF="${AIGON_HOST_TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
NP="${ROOT}/config/notify-policy.yaml"
if [ -r "$NP" ]; then
  MF="$(python3 - "$NP" <<'PY' 2>/dev/null
import sys, yaml
try:
    print(((yaml.safe_load(open(sys.argv[1])) or {}).get("runtime") or {}).get("metrics_file", "") or "")
except Exception:
    print("")
PY
)"
  if [ -z "$MF" ]; then
    bad "EXPC-020 brak runtime.metrics_file w ${NP} — producent metryk bez zadeklarowanego pliku"
  elif [ "$(dirname "$MF")" != "$TF" ]; then
    bad "EXPC-020 metryki powiadomień POZA katalogiem zbieranym ($MF != $TF) — Prometheus ich nie zobaczy"
  elif [ ! -f "$MF" ]; then
    warn "EXPC-020 plik metryk jeszcze nie istnieje ($MF) — sprawdzi się po pierwszym przebiegu"
  elif [ "$(stat -c %a "$MF")" -lt 644 ] 2>/dev/null; then
    bad "EXPC-020 metryki powiadomień nieczytelne dla node_exportera (tryb $(stat -c %a "$MF"))"
  else
    ok "EXPC-020 metryki powiadomień w katalogu zbieranym i czytelne ($MF)"
  fi
fi
# każdy plik .prom w katalogu zbieranym MUSI mieć bit czytania dla 'others'
if [ -d "$TF" ]; then
  NU="$(find "$TF" -maxdepth 1 -name '*.prom' ! -perm -o=r 2>/dev/null | wc -l)"
  for _f in $(find "$TF" -maxdepth 1 -name '*.prom' ! -perm -o=r 2>/dev/null | head -5); do
    bad "EXPC-021 metryka nieczytelna dla node_exportera: $(basename "$_f") — pisarz tworzy plik przez mktemp (0600) bez chmod 0644"
  done
  [ "${NU:-0}" -eq 0 ] && ok "EXPC-021 wszystkie pliki .prom czytelne dla node_exportera"
fi

# ── 6. CRON: każdy producent w SSOT **i** w żywym pliku ──────────────────
declare -A PRODUCERS=(
  [aigon-ollama-spin-guard.sh]="spin ollamy"
  [aigon-mcp-exporter.sh]="serwery MCP"
  [aigon-mesh-nodes-exporter.sh]="stan węzłów mesha"
  [state-ratchet-exporter.sh]="ratchet stanu"
  # Dodane 2026-10-14 po zmierzonym defekcie: gateway powiadomień pisał metryki
  # do /var/lib/aigon/ (POZA katalogiem zbieranym), więc Prometheus nie miał ani
  # jednej serii aigon_notify_* — a ten gejt miał dokładnie tę klasę łapać.
  [notify-gateway.py]="droga alertu (metryki kanałów i eskalacji)"
  [aigon-szpieg-exporter.sh]="kontrakt SZPIEG (metryki warstwy nadzoru)"
)
for f in "${!PRODUCERS[@]}"; do
  if [ -f "$CRON_SSOT" ] && grep -q "$f" "$CRON_SSOT" 2>/dev/null; then
    ok "EXPC-010/$f w SSOT cronu (${PRODUCERS[$f]})"
  else
    bad "EXPC-010/$f BRAK w ${CRON_SSOT} — producent nie odpali się cyklicznie"
  fi
done
if [ -r "$CRON_LIVE" ]; then
  for f in "${!PRODUCERS[@]}"; do
    if grep -q "$f" "$CRON_LIVE" 2>/dev/null; then
      ok "EXPC-011/$f w ŻYWYM cronie (${PRODUCERS[$f]})"
    else
      bad "EXPC-011/$f BRAK w ${CRON_LIVE} — SSOT != żywy plik; uruchom: sudo python3 scripts/sync-cron.py"
    fi
  done
else
  warn "EXPC-011 nie mogę przeczytać ${CRON_LIVE} (brak uprawnień) — nie wiem, czy SSOT dotarł do cronu"
fi

# ── 7. Pliki textfile producentów faktycznie istnieją (dowód działania) ──
if [ -d "$TEXTFILE" ]; then
  for pf in aigon-ollama-spin.prom aigon-mcp.prom aigon-mesh-nodes.prom aigon-state-ratchet.prom; do
    if [ -f "${TEXTFILE}/${pf}" ]; then
      ok "EXPC-012 ${pf} obecny (dowód, że producent pisze)"
    else
      warn "EXPC-012 brak ${TEXTFILE}/${pf} — producent zadeklarowany, ale nie zostawił pliku (świeży, albo nie działa)"
    fi
  done
else
  warn "EXPC-012 brak katalogu ${TEXTFILE} — nie mogę potwierdzić plików metryk"
fi

echo
echo "=== RESULT ==="
echo "Checks: $((PASS+FAIL+WARN))  PASS: ${PASS}  FAIL: ${FAIL}  WARN: ${WARN}"
if [ "$FAIL" -gt 0 ]; then
  echo "CERTIFICATION: FAIL — kontrakt producenta telemetrii złamany (zielone światło byłoby fałszywe)"
  exit 1
fi
if [ "$WARN" -gt 0 ]; then
  echo "CERTIFICATION: PASS z ostrzeżeniami"
  exit 0
fi
echo "CERTIFICATION: PASS"
exit 0

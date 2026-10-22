#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/leonardo-campaign.sh — BRAMKA KAMPANII FL01-760
#
#  PO CO (kontrakt wykonawczy PLAN-KAMPANII-FL01-760.md §12.5, kryteria a-d):
#    Kampania „wpięta w runtime" bez bramki jest życzeniem: pętla może
#    wysyłać w pustkę, mierzyć nieistniejące tempo albo gubić rozjazd.
#    Ta bramka mówi JEDNYM werdyktem, czy kampania jest ZDROWA.
#
#  PASS tylko gdy JEDNOCZEŚNIE:
#    (a) istnieje ŚWIEŻY pomiar tempa (§12.4): metryka burn_rate + świeżość
#        znacznika eksportera (domyślnie <= 3600 s),
#    (b) kolejka ma co najmniej jedną pozycję oczekującą ALBO wszystkie
#        pozycje są done/pass (semantyka z manifestu: queue_depth > 0),
#    (c) brak driftu z ostatniej rewizji (snapshot revision-<data>.json
#        istnieje i ma drift == 0),
#    (d) nowe komponenty emitują spany OTEL (rejestr
#        config/canonical/otel-span-registry.txt).
#
#  TEST NEGATYWNY (kanon: strażnik bez testu negatywnego nie wiadomo czy żyje):
#    każdą sekcję można zapalić env-em —
#      AIGON_LEONARDO_PROM=<plik bez burn_rate>      → (a) FAIL
#      AIGON_LEONARDO_STATE_DIR=<stan z depth=0>     → (b) FAIL
#      AIGON_LEONARDO_REVISION=<snapshot drift>0>    → (c) FAIL
#      AIGON_LEONARDO_OTEL_REGISTRY=<pusty plik>     → (d) PASS (brak długu)
#    Przebieg negatywny jest w tests/leonardo/run-campaign-tests.sh (N1-N4).
#
#  KONTRAKT: exit 0 = PASS, exit 1 = FAIL. Env: --json (raport maszynowy).
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
JSON=0
[ "${1:-}" = "--json" ] && JSON=1

PROM="${AIGON_LEONARDO_PROM:-/var/lib/node_exporter/textfile_collector/aigon-leonardo.prom}"
STATE_DIR_LEO="${AIGON_LEONARDO_STATE_DIR:-/var/lib/aigon/leonardo-keepfull}"
STATE_JSON="$STATE_DIR_LEO/queue-state.json"
QUEUE="${AIGON_LEONARDO_QUEUE:-$ROOT/products/akceleratory/leonardo/config/leonardo-queue.yaml}"
OTEL_REGISTRY="${AIGON_LEONARDO_OTEL_REGISTRY:-$ROOT/config/canonical/otel-span-registry.txt}"
MAX_AGE="${AIGON_LEONARDO_MAX_PROM_AGE:-3600}"
REVISION="${AIGON_LEONARDO_REVISION:-}"

fails=0
declare -a RESULTS
say() { printf '       %s\n' "$*"; }
mark() { RESULTS+=("$1|$2|$3"); [ "$2" = "FAIL" ] && fails=$((fails+1)); }

# ── (a) ŚWIEŻY POMIAR TEMPA ────────────────────────────────────────────
a_status=FAIL; a_note=""
if [ -r "$PROM" ]; then
  burn="$(awk '/^aigon_leonardo_burn_rate_gpuh_per_h/{print $2; exit}' "$PROM" 2>/dev/null)"
  last="$(awk '/^aigon_leonardo_exporter_last_run_timestamp_seconds/{print $2; exit}' "$PROM" 2>/dev/null)"
  now="$(date -u +%s)"
  if [ -z "$burn" ]; then
    a_note="brak metryki burn_rate w $PROM (front METERING jej nie wyemitował)"
  elif [ -z "$last" ]; then
    a_note="brak znacznika świeżości (exporter_last_run_timestamp_seconds)"
  else
    age=$(( now - ${last%.*} ))
    if [ "$age" -gt "$MAX_AGE" ]; then
      a_note="pomiar NIEAKTUALNY: wiek ${age}s > ${MAX_AGE}s"
    elif [ "${burn%.*}" -lt 0 ] 2>/dev/null; then
      a_note="burn_rate=${burn} (<0 = nie policzono; pomiar bezwartościowy)"
    else
      a_status=PASS; a_note="burn_rate=${burn} GPU-h/h, wiek pomiaru=${age}s"
    fi
  fi
else
  a_note="brak pliku pomiaru $PROM"
fi
mark "(a) świeży pomiar tempa" "$a_status" "$a_note"

# ── (b) KOLEJKA: depth > 0 ALBO wszystko done/pass ─────────────────────
b_status=FAIL; b_note=""
b_json="$(python3 - "$STATE_JSON" "$QUEUE" <<'PY' 2>/dev/null
import json, sys, os
state_p, queue_p = sys.argv[1], sys.argv[2]
try:
    import yaml
    q = yaml.safe_load(open(queue_p, encoding="utf-8")) or {}
    enabled = [i["id"] for i in (q.get("items") or []) if i.get("enabled", True)]
except Exception as e:
    print(f"ERR|manifest:{e}"); raise SystemExit
try:
    st = json.load(open(state_p, encoding="utf-8")).get("items", {}) or {}
except Exception:
    st = {}
WAITING = {"new", "submitted", "active", "ready_next_stage", "infra_failed"}
DONE = {"done", "pass"}
waiting = 0; finished = 0
for iid in enabled:
    status = (st.get(iid) or {}).get("status", "new")
    if status in WAITING:
        waiting += 1
    elif status in DONE:
        finished += 1
print(f"OK|{waiting}|{finished}|{len(enabled)}")
PY
)"
if [ "$(printf '%s' "$b_json" | cut -d'|' -f1)" = "OK" ]; then
  waiting="$(printf '%s' "$b_json" | cut -d'|' -f2)"
  finished="$(printf '%s' "$b_json" | cut -d'|' -f3)"
  total="$(printf '%s' "$b_json" | cut -d'|' -f4)"
  if [ "$waiting" -gt 0 ]; then
    b_status=PASS; b_note="kolejka ma ${waiting} oczekujących (enabled=${total})"
  elif [ "$total" -gt 0 ] && [ "$finished" -eq "$total" ]; then
    b_status=PASS; b_note="wszystkie ${total} pozycje done/pass — kolejka domknięta"
  else
    b_note="queue_depth=0 przy ${total} pozycjach (${finished} done) — PUSTA KOLEJKA to alarm, nie spokój"
  fi
else
  b_note="nie mogę policzyć kolejki (${b_json#ERR|}${STATE_JSON:+ }; stan=$STATE_JSON)"
fi
mark "(b) queue_depth > 0 albo wszystko done" "$b_status" "$b_note"

# ── (c) BRAK DRIFTU Z OSTATNIEJ REWIZJI ────────────────────────────────
c_status=FAIL; c_note=""
snap="$REVISION"
[ -n "$snap" ] || snap="$(ls -1t "$STATE_DIR_LEO"/revision-*.json 2>/dev/null | head -1)"
if [ -n "$snap" ] && [ -r "$snap" ]; then
  drift="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(len(d.get('drift',[]) or []))" "$snap" 2>/dev/null)"
  if [ -z "$drift" ]; then
    c_note="snapshot nieczytelny: $snap"
  elif [ "$drift" -gt 0 ]; then
    c_note="DRIFT: ${drift} rozjazdów w $(basename "$snap") — wymaga korekty"
  else
    c_status=PASS; c_note="rewizja $(basename "$snap"): drift=0"
  fi
else
  c_note="brak snapshotu rewizji w $STATE_DIR_LEO (rewizja nie biegała — nie wiem ≠ OK)"
fi
mark "(c) brak driftu z ostatniej rewizji" "$c_status" "$c_note"

# ── (d) NOWE KOMPONENTY EMITUJĄ SPANY OTEL ─────────────────────────────
d_status=PASS; d_note="brak zarejestrowanych komponentów"
if [ -r "$OTEL_REGISTRY" ]; then
  missing_emit=(); missing_file=()
  while IFS='|' read -r path marker; do
    path="${path%%#*}"; path="$(printf '%s' "$path" | tr -d '[:space:]')"
    [ -n "$path" ] || continue
    marker="${marker## }"; marker="${marker%% }"
    [ -n "$marker" ] || marker="otel_span_emit"
    full="$path"; [ "${path#/}" = "$path" ] && full="$ROOT/$path"
    if [ ! -f "$full" ]; then
      missing_file+=("$path"); continue
    fi
    grep -q "$marker" "$full" 2>/dev/null || missing_emit+=("$path")
  done < "$OTEL_REGISTRY"
  if [ "${#missing_file[@]}" -gt 0 ]; then
    d_status=FAIL; d_note="rejestr wskazuje nieistniejące pliki: ${missing_file[*]}"
  elif [ "${#missing_emit[@]}" -gt 0 ]; then
    d_status=FAIL; d_note="komponenty bez emisji spanu: ${missing_emit[*]}"
  else
    d_status=PASS; d_note="wszystkie zarejestrowane komponenty emitują spany OTEL"
  fi
elif [ -z "$AIGON_LEONARDO_OTEL_REGISTRY" ]; then
  # BRAK rejestru = nie mogę dowieść pokrycia spanami → FAIL (fail-closed).
  # Nie blokuję cudzych przebiegów fałszywym PASS-em; mówię wprost, czego nie wiem.
  d_note="brak rejestru $OTEL_REGISTRY — nie mogę dowieść pokrycia spanami"
else
  d_note="rejestr nieczytelny: $OTEL_REGISTRY"
fi
mark "(d) spany OTEL nowych komponentów" "$d_status" "$d_note"

# ── RAPORT ─────────────────────────────────────────────────────────────
echo "leonardo-campaign: $( [ "$fails" -eq 0 ] && echo PASS || echo FAIL )"
for r in "${RESULTS[@]}"; do
  IFS='|' read -r name st note <<< "$r"
  printf '  [%s] %s — %s\n' "$st" "$name" "$note"
done

# Metryka textfile (LAW-OBS-1): werdykt bramki ma ślad w Prometheusie.
TEXTFILE="${AIGON_HOST_TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
if mkdir -p "$TEXTFILE" 2>/dev/null && [ -w "$TEXTFILE" ]; then
  {
    echo "# HELP aigon_leonardo_campaign_gate_pass Werdykt bramki kampanii (1=PASS, 0=FAIL)"
    echo "# TYPE aigon_leonardo_campaign_gate_pass gauge"
    echo "aigon_leonardo_campaign_gate_pass $([ "$fails" -eq 0 ] && echo 1 || echo 0)"
    echo "# HELP aigon_leonardo_campaign_gate_timestamp_seconds Epoch przebiegu bramki"
    echo "# TYPE aigon_leonardo_campaign_gate_timestamp_seconds gauge"
    echo "aigon_leonardo_campaign_gate_timestamp_seconds $(date -u +%s)"
  } > "$TEXTFILE/aigon-leonardo-campaign-gate.prom.tmp" 2>/dev/null \
    && mv "$TEXTFILE/aigon-leonardo-campaign-gate.prom.tmp" "$TEXTFILE/aigon-leonardo-campaign-gate.prom" 2>/dev/null
fi

# Span OTEL bramki — bramka, która nie zostawia śladu, nie istnieje w Tempo.
if [ -r "$ROOT/scripts/lib/otel-span.sh" ]; then
  # shellcheck source=/dev/null
  . "$ROOT/scripts/lib/otel-span.sh"
  command -v otel_span_emit >/dev/null 2>&1 && \
    otel_span_emit "aigon-leonardo-campaign" "leonardo.campaign.gate" \
      pass="$([ "$fails" -eq 0 ] && echo 1 || echo 0)" fails="$fails" >/dev/null 2>&1 || true
fi

if [ "$JSON" = 1 ]; then
  python3 - "${RESULTS[@]}" <<'PY' 2>/dev/null || true
import json, sys
out = []
for r in sys.argv[1:]:
    name, st, note = r.split("|", 2)
    out.append({"criterion": name, "status": st, "note": note})
print(json.dumps({"gate": "leonardo-campaign", "pass": all(x["status"] == "PASS" for x in out),
                  "criteria": out}, ensure_ascii=False))
PY
fi

[ "$fails" -eq 0 ] && exit 0
exit 1

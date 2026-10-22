#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/llama-runner-churn.sh — gate LLAMA-RUNNER-CHURN
#
#  PO CO (rozkaz Suwerena 2026-09-29: „musimy zrobić na to jakiegoś
#  checkera, otela i tempo, bo co chwile coś wstaje"):
#    ZMIERZONE na prod-aigon: **11 startów `llama-server` w 30 minut** —
#    co ~3 min ollama ładuje model OD ZERA. Każdy start = pełne czytanie wag
#    z dysku + alokacja KV w RAM + skok CPU, a przy okazji zabija odpowiedź
#    (load timeout). To jest bezpośrednia przyczyna load 68-91 na 14 rdzeniach.
#
#    DODATKOWO: ollama 0.33.3 startuje model z `-c` równym POJEMNOŚCI
#    architektury, nie okna serwera — zmierzone: qwen2.5-coder:0.5b ma
#    `context_length = 32768`, a runner dostał `-c 65536` (2× więcej).
#    To marnuje KV i nie da się tego nadpisać env (patrz runbook
#    docs/runbooks/ollama-num-ctx-limitation.md).
#
#  CO MIERZY (3 warstwy, w tej kolejności):
#    1. CHURN: ile startów `llama-server` w oknie 30 min (próg CHURN_MAX,
#       def. 6 = 1 start / 5 min). Powyżej = FAIL.
#    2. OKNO: czy jakikolwiek runner ma `-c` WIĘKSZE niż pojemność modelu
#       (nadmiar KV = marnotrawstwo RAM i CPU).
#    3. MARTWE RUNNERY: procesy `llama-server`, których modelu NIE MA już
#       w `ollama list` (osierocone — zajmują RAM bez konsumenta).
#
#  KONTRAKT: exit 0 = PASS, exit 1 = FAIL.
#  Env: LLAMA_CHURN_MAX (def. 6), LLAMA_CHURN_WINDOW_MIN (def. 30).
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHURN_MAX="${LLAMA_CHURN_MAX:-6}"
WINDOW_MIN="${LLAMA_CHURN_WINDOW_MIN:-30}"
export PATH="/usr/bin:/usr/local/bin:$PATH"

fails=0
say() { printf '       %s\n' "$*"; }

# ── 1. CHURN: starty runnera w oknie ────────────────────────────────────
# Uwaga: `grep -c` w pipeline z `|| echo 0` potrafi dokleić drugą linię,
# gdy journalctl zwróci błąd — bierzemy pierwszą linię i czyścimy do cyfr.
starts=$(journalctl -u ollama --since "${WINDOW_MIN} min ago" --no-pager 2>/dev/null \
         | grep -c "starting llama-server" | head -1 | tr -dc '0-9')
starts="${starts:-0}"
say "starty llama-server w ${WINDOW_MIN} min: ${starts} (prog ${CHURN_MAX})"
if [ "${starts:-0}" -gt "$CHURN_MAX" ]; then
  say "FAIL: runner startuje ${starts}× w ${WINDOW_MIN} min — to CHURN (co ~$((WINDOW_MIN*60/starts))s)"
  say "      Skutek: model czytany od zera, KV alokowane w kolko, load rosnie, odpowiedzi timeoutuja"
  fails=$((fails+1))
fi

# ── 2. OKNO vs POJEMNOSC modelu ─────────────────────────────────────────
# Dla KAŻDEGO runnera: wyciągnij jego blob, znajdź model o TYM blobie
# w /api/tags, weź jego `context_length` z /api/show i porównaj z `-c`.
# UWAGA: nie da się dopasować "po wartości" (poprzednia wersja brała pierwszą
# lepszą pojemność, np. 2 od nomic-embed) — trzeba iść po blob → nazwa → ctx.
tags_raw=$(curl -s -m 8 http://127.0.0.1:11445/api/tags 2>/dev/null)
over=0
while IFS= read -r line; do
  # pomiń embedding (ma własne, małe okno)
  echo "$line" | grep -q -- "--embedding" && continue
  blob=$(echo "$line" | grep -oE 'blobs/sha256-[a-f0-9]+' | sed 's|.*sha256-||')
  ctx=$(echo "$line" | grep -oE '\-c [0-9]+' | head -1 | awk '{print $2}')
  [ -z "$ctx" ] || [ -z "$blob" ] && continue
  # nazwa modelu, którego digest zaczyna się tym blobem (tags zwraca digest=blob)
  model=$(printf '%s' "$tags_raw" | tr '}' '\n' \
          | grep "$blob" | grep -oE '"name":"[^"]+"' | cut -d'"' -f4 | head -1)
  [ -z "$model" ] && continue
  cap=$(curl -s -m 6 http://127.0.0.1:11445/api/show -d "{\"model\":\"$model\"}" 2>/dev/null \
        | grep -oE '\.context_length": *[0-9]+' | grep -oE '[0-9]+' | head -1)
  cap="${cap:-0}"
  if [ "$cap" -gt 0 ] && [ "$ctx" -gt "$cap" ]; then
    say "FAIL: runner ${model} ma -c ${ctx} > pojemnosc ${cap} — nadmiar KV x$((ctx/cap))"
    over=$((over+1))
  fi
done < <(ps -eo pid,args 2>/dev/null | grep "[l]lama-server")
[ "$over" -gt 0 ] && fails=$((fails+1))

# ── 3. OSIEROCONE runnery (model usuniety z ollamy) ─────────────────────
live_models=$(curl -s -m 8 http://127.0.0.1:11445/api/tags 2>/dev/null \
              | grep -oE '"name":"[^"]+"' | cut -d'"' -f4 | tr '\n' '|')
orph=0
while IFS= read -r line; do
  blob=$(echo "$line" | grep -oE 'blobs/sha256-[a-f0-9]+' | sed 's|.*sha256-||')
  nm=$(echo "$line" | grep -oE '\-\-model [^ ]+' | awk '{print $2}')
  [ -z "$nm" ] && continue
  # modelu nie ma w liscie ZADNEGO zywego modelu po nazwie pliku? -> osierocony
  if [ -n "$blob" ] && ! grep -q "$blob" <<<"$(curl -s -m 8 http://127.0.0.1:11445/api/tags 2>/dev/null)"; then
    say "WARN: runner pid=$(echo "$line" | awk '{print $1}') trzyma blob ${blob:0:12} — modelu nie ma w /api/tags (osierocony?)"
    orph=$((orph+1))
  fi
done < <(ps -eo pid,args 2>/dev/null | grep "[l]lama-server")

# ── Metryka textfile — żeby Prometheus/alert to widział ────────────────
PROM_DIR="/var/lib/node_exporter/textfile_collector"
if [ -d "$PROM_DIR" ]; then
  {
    echo "# HELP aigon_llama_runner_starts_30m starty llama-server w oknie 30 min"
    echo "# TYPE aigon_llama_runner_starts_30m gauge"
    echo "aigon_llama_runner_starts_30m ${starts:-0}"
    echo "# HELP aigon_llama_runner_ctx_over_capacity runnery z -c > pojemnosc modelu"
    echo "# TYPE aigon_llama_runner_ctx_over_capacity gauge"
    echo "aigon_llama_runner_ctx_over_capacity ${over}"
    echo "# HELP aigon_llama_runner_orphans runnery trzymajace blob bez modelu w /api/tags"
    echo "# TYPE aigon_llama_runner_orphans gauge"
    echo "aigon_llama_runner_orphans ${orph}"
    echo "# HELP aigon_llama_runner_churn_last_run unix epoch"
    echo "# TYPE aigon_llama_runner_churn_last_run gauge"
    echo "aigon_llama_runner_churn_last_run $(date +%s)"
  } > "${PROM_DIR}/aigon-llama-runner-churn.prom.tmp" 2>/dev/null \
    && mv "${PROM_DIR}/aigon-llama-runner-churn.prom.tmp" \
          "${PROM_DIR}/aigon-llama-runner-churn.prom" 2>/dev/null
fi

# ── OTel span (Tempo) — ślad audytowy ROZKAZ Suwerena „checkera otela i tempo"
# Droga UDOWODNIONA w Tempo: lib/otel_span.py (emit_span, czysty POST
# /v1/traces, bez SDK). Moduł aigon_otel (SDK) nie dowoził śladu przy krótkim
# procesie. Wzorzec skopiowany z hermes-state-maintenance.sh (działa).
OTEL_LIB="$ROOT/scripts/lib/otel_span.py"
if [ -f "$OTEL_LIB" ]; then
  timeout 25 /usr/bin/python3 -c "
import sys
sys.path.insert(0, '$ROOT/scripts/lib')
import os
os.environ.setdefault('AIGON_OTLP_ENDPOINT', 'https://100.98.144.70:44318')
try:
    from otel_span import emit_span
    emit_span('llama-runner-churn', 'llama.churn.audit',
              starts=${starts:-0}, ctx_over=${over}, orphans=${orph},
              fails=${fails}, kind='gate')
except Exception:
    pass
" 2>/dev/null || true
fi

if [ "$fails" -eq 0 ]; then
  echo "llama-runner-churn: PASS (${starts} startow/${WINDOW_MIN}min, ${over} nadmiar okna, ${orph} osieroconych)"
  exit 0
fi
echo "llama-runner-churn: FAIL (${fails} asercji: churn=${starts}, okno>pojemnosc=${over})"
exit 1

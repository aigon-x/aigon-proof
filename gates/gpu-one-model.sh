#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/gpu-one-model.sh — gate gpu-one-model (hook-runner)
#
#  KANON 2026-09-04 (Suweren): GPU local-aigon (RTX 5090, 24 GB VRAM)
#  trzyma JEDEN duży model — Qwen3.6-27B-A3B-Coder-MTP (ManniX GGUF Q4_K_M,
#  ~17 GB, MoE ~3B aktywne, ~40-98 tok/s). qwythos-27b/9b ZOSTAŁY WYCOFANE
#  (Gated-DeltaNet bez CUDA = CPU 5 t/s + kolaps termiczny 95C) i USUNIĘTE
#  z rejestru ollamy (ollama rm, 2026-09-04, ~46 GB zwolnione).
#
#  Stare nazwy qwythos-* NIE są aliasowane — wołanie ich ma dać 404
#  (błąd ujawnia stale referencje w configach), a nie cichy fallback
#  na wycofany model. ADR-020 zastąpione przez ten kanon.
#
#  KANON 2026-09-05 (Suweren): dozwolone DUŻE modele = A3B (27c70e1c2a35)
#  ORAZ heretic:latest (e540965e94f8, qwen35 dense 26.9B) — celowy model
#  innego agenta na tym samym GPU.
#  KOREKTA 2026-09-06: ManniX (27c70e1c2a35) i heretic (e540965e94f8)
#  WYCOFANE kanonem 2026-09-05 („wypierdolone z ollamy i configów, nie
#  odtwarzać") — jedyny dozwolony duży model = Huihui (70a25ee18ddc).
#  Uwaga: 24 GB VRAM mieści JEDEN taki model naraz; rejestr też tylko Huihui.
#
#  CO SPRAWDZA (żywy stan GPU, nie diff!):
#    1. Brak GPU (nvidia-smi) → PASS (gate dotyczy tylko noda z GPU).
#    2. Resident duży model (>6 GB) musi być Huihui (70a25ee18ddc).
#       Każdy inny duży model na GPU (qwythos-27b/9b, 30b, ManniX, heretic…) → FAIL.
#    3. Rejestr (ollama list): duże wpisy (>6 GB) POZA Huihui → FAIL
#       (np. qwen3-coder:30b, qwythos-*, heretic, ManniX-*) — usuń przez ollama rm.
#    4. Churn w logach ollamy (10 min): start llama-server z wagami
#       qwythos-27b/9b (blob f9d2a9123383) → FAIL (to był objaw churnu).
#
#  Kontrakt z hook-runner.sh:
#    exit 0 = PASS
#    exit 1 = FAIL (złamany kanon jednego modelu — blokada push)
#    exit 2 = WARN (ollama nieosiągalna / brak danych — nie blokuje)
#
#  Zmienne env do testów:
#    AIGON_G1M_OLLAMA_PS  — podmiana wyjścia `ollama ps`
#    AIGON_G1M_OLLAMA_LIST — podmiana wyjścia `ollama list`
#    AIGON_G1M_JOURNAL    — podmiana wyjścia `journalctl -u ollama`
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

# ── Identyfikatory (kanon 2026-09-04 + 2026-09-05; po zmianie wag zaktualizuj ten blok)
# KOREKTA 2026-09-06: ManniX (A3B_ID) i heretic WYCOFANE kanonem 2026-09-05 —
# allowlista trzyma WYŁĄCZNIE kanoniczny model Huihui. Historia w komentarzach.
# A3B_ID="27c70e1c2a35"        # WYCOFANY: hf.co/ManniX-ITA/Qwen3.6-27B-A3B-Coder-MTP-GGUF:Q4_K_M
# HERETIC_ID="e540965e94f8"    # WYCOFANY: heretic:latest (qwen35 dense 26.9B)
# KANON 2026-09-24 (Suweren: przelaczenie modelu GPU) — dozwolone duze ID:
#   CODER30_ID / KEEP30B_ID — Huihui-Qwen3-Coder-30B (kanon 2026-09-05) ZACHOWANY
#     jako *_original = sciezka powrotu; wagi zostaja w rejestrze celowo.
#   GO20_CANON_ID — alias kanoniczny hf.co/mradermacher/Huihui-Qwen3-Coder-30B-...:Q4_K_M,
#     ktorego NAZWA jest wkompilowana w backend-rs (proxy.rs:409 LOCAL_MODEL) i dlatego
#     musi zostac, a niesie juz wagi gpt-oss-20b MXFP4.
#   GO20_NAME_ID / GO20_RAW_ID — gpt-oss-20b-abliterated:latest (jawna nazwa) oraz
#     pobranie zrodlowe hf.co/huihui-ai/Huihui-gpt-oss-20b-mxfp4-abliterated-v2.
#   WSZYSTKIE TRZY warianty gpt-oss dziela TEN SAM blob wag (db7fa5d5c20375b9...)
#   — to trzy nazwy JEDNEGO modelu, nie trzy modele. Warunek "dokladnie JEDEN
#   rezydentny duzy model" (check 2b) obowiazuje BEZ ZMIAN.
CODER30_ID="70a25ee18ddc"   # Huihui-Qwen3-Coder-30B-A3B-abliterated Q4_K_M (kanon 2026-09-05; zachowany)
GO20_CANON_ID="5645a529b160"  # alias kanoniczny <- wagi gpt-oss-20b MXFP4 (kanon 2026-09-24)
GO20_NAME_ID="95bfcd614539"   # gpt-oss-20b-abliterated:latest (ta sama waga, jawna nazwa)
GO20_RAW_ID="f3b6f337191f"    # hf.co/huihui-ai/Huihui-gpt-oss-20b-mxfp4-abliterated-v2:latest
KEEP30B_ID="d66bec0c51d8"     # huihui-30b-qwen3coder-original:latest (fallback do 30B)
# Nazwy kanoniczne (SSOT: config/agent-models.yaml -> ollama.gpu.allowed_model_names)
CANON_NAME="hf.co/mradermacher/Huihui-Qwen3-Coder-30B-A3B-Instruct-abliterated-GGUF:Q4_K_M"
GO20_NAME="gpt-oss-20b-abliterated:latest"
RAW_NAME="hf.co/huihui-ai/Huihui-gpt-oss-20b-mxfp4-abliterated-v2:latest"
KEEP30B_NAME="huihui-30b-qwen3coder-original:latest"
QW_BLOB="f9d2a9123383"       # blob wag qwythos-27b/9b (wycofane — ich load = churn)

# Dozwolone duże modele (resident i rejestr) — KOREKTA 2026-09-06: tylko Huihui.
ALLOWED_BIG_IDS="$CODER30_ID $GO20_CANON_ID $GO20_NAME_ID $GO20_RAW_ID $KEEP30B_ID"
is_allowed_big() { # <id>
  for allowed in $ALLOWED_BIG_IDS; do
    [ "$1" = "$allowed" ] && return 0
  done
  return 1
}

if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "PASS gpu-one-model (brak GPU na tym nodzie — gate nie dotyczy)"
  exit 0
fi

# ── Ollama reachability: bare `ollama` default endpoint może nie odpowiadać na tym hoście
#    (znany objaw nieosiągalności mimo żywej usługi) — próbuj kandy daty: AIGON kanon
#    GPU :11436 (bezpośrednio, live GPU state), auth proxy :11434, potem domyślny.
is_ollama() { # próbuje ustawić PS_OUT/LIST_OUT na dany host; zwraca 0 gdy oba niepuste
  local h="$1"
  if [ -n "$h" ]; then PS_OUT=$(OLLAMA_HOST="$h" ollama ps 2>/dev/null); LIST_OUT=$(OLLAMA_HOST="$h" ollama list 2>/dev/null);
  else PS_OUT=$(ollama ps 2>/dev/null); LIST_OUT=$(ollama list 2>/dev/null); fi
  [ -n "$PS_OUT" ] && [ -n "$LIST_OUT" ]
}
PS_OUT=; LIST_OUT=
if [ -n "${OLLAMA_HOST:-}" ] && is_ollama "$OLLAMA_HOST"; then :;fi
[ -z "$PS_OUT" ] && is_ollama "127.0.0.1:11436" && :;
[ -z "$PS_OUT" ] && is_ollama "127.0.0.1:11434" && :
[ -z "$PS_OUT" ] && is_ollama "" && :
if [ -z "$PS_OUT" ] || [ -z "$LIST_OUT" ]; then
  echo "WARN gpu-one-model (ollama nieosiągalna — watchdog zajmie się restartem)"
  exit 2
fi

# ── ALLOWLISTA Z SSOT (kanon 2026-09-24) ──────────────────────────────────
#  Nazwy dozwolonych modeli zyja w config/agent-models.yaml -> ollama.gpu.
#  ID rozwiazujemy ZYWO z `ollama list`, bo ID liczy sie z MANIFESTU i zmienia
#  sie po kazdej edycji manifestu (patch template/params) — twarde ID cicho
#  rozbrajalo allowliste (zmierzone 2026-09-24: 434456081734 -> f3b6f337191f).
#  Fallback: stala lista nizej (gdy SSOT nieczytelny — WARN, nie FAIL).
_SSOT="${AIGON_GPU_SSOT:-/opt/PROD/config/agent-models.yaml}"
_ssot_names=$(sed -n '/^  gpu:/,/^  [a-zA-Z_]/p' "$_SSOT" 2>/dev/null \
              | sed -n '/allowed_model_names:/,/^    [a-zA-Z_]/p' \
              | grep -oE "^ *- '[^']+'" | sed "s/^ *- '\(.*\)'$/\1/")
_resolved=""
for _n in $_ssot_names "$CANON_NAME" "$GO20_NAME" "$RAW_NAME" "$KEEP30B_NAME"; do
  _id=$(printf '%s\n' "$LIST_OUT" | awk -v n="$_n" '$1==n {print $2; exit}')
  [ -n "$_id" ] && case " $_resolved " in *" $_id "*) ;; *) _resolved="$_resolved $_id";; esac
done
[ -n "$_resolved" ] && ALLOWED_BIG_IDS="$_resolved"
ALLOWED_BIG_IDS="$ALLOWED_BIG_IDS $CODER30_ID"
echo "INFO gpu-one-model (allowlista: names_ssot=$(printf '%s' "$_ssot_names" | wc -w) ids_resolved=$(printf '%s' "$_resolved" | wc -w))" >&2

FAILS=""
WARNS=""


# ── 2. Resident duży model musi być A3B ────────────────────────────────
# Kolumny ollama ps: NAME ID SIZE PROCESSOR CONTEXT UNTIL
while IFS= read -r line; do
  case "$line" in
    NAME*) continue ;;
    "") continue ;;
  esac
  name=$(echo "$line" | awk '{print $1}')
  id=$(echo "$line" | awk '{print $2}')
  size=$(echo "$line" | awk '{print $3}')
  unit=$(echo "$line" | awk '{print $4}')
  # tylko modele znaczące (>=6 GB) — embed (MB)/0.5b/1.5b/3b/7b nie łamią kanonu
  [ "$unit" = "GB" ] || continue
  size_gb=$(echo "$size" | cut -d. -f1)
  [ "${size_gb:-0}" -ge 6 ] || continue
  if ! is_allowed_big "$id"; then
    FAILS="$FAILS | resident '$name' (ID $id, ${size}) — nie jest Huihui (kanon 2026-09-05)"
  fi
done <<< "$PS_OUT"

# ── 2b. LICZBA modeli rezydentnych — MUSI byc dokladnie JEDEN ─────────
# KANON 2026-09-19. Do tej daty gate NIE LICZYL modeli mimo nazwy
# "gpu-one-model": sprawdzal wylacznie, czy DUZY model to Huihui, a warunek
# `[ "$size_gb" -ge 6 ] || continue` przepuszczal kazdy maly model bez sladu.
# Zmierzony skutek FALSE-GREEN: Huihui 21.9 GiB + qwen2.5-coder:0.5b 1.2 GiB
# = 23.1/23.9 GiB VRAM, brak pamieci na kontekst, 65 zadan w kolejce haproxy,
# burza 503 na calym stacku — przy gate mowiacym PASS w tej samej minucie.
# Maly model na GPU NIE jest niewinny: kradnie VRAM kontekstowi 30B.
RESIDENT=$(echo "$PS_OUT" | awk 'NR>1 && NF>0 {n++} END {print n+0}')
if [ "${RESIDENT:-0}" -gt 1 ]; then
  RES_LIST=$(echo "$PS_OUT" | awk 'NR>1 && NF>0 {printf "%s(%s%s) ", $1, $3, $4}')
  FAILS="$FAILS | na GPU rezyduje $RESIDENT modeli zamiast 1: $RES_LIST"
  FAILS="$FAILS | sprawdz OLLAMA_MAX_LOADED_MODELS (kanon=1) w /etc/systemd/system/ollama.service.d/vram-limit.conf"
fi

# ── 2c. GHOST: deklaracja ollamy vs POMIAR z GPU (dodane 2026-09-30) ──────
# ZMIERZONE 2026-09-30 (rozkaz Suwerena "napraw na zawsze"): bramka mowila PASS
# ("DOKLADNIE JEDEN duzy model rezydentny"), a pasmo GPU bylo MARTWE:
#   * `/api/ps` deklarowalo gpt-oss-20b rezydentny (12 GB, "100% GPU, Forever"),
#   * nvidia-smi: 236 MiB (Xorg+gnome-shell), ZERO procesow compute ollamy,
#   * `POST /api/generate` wisial 120 s bez odpowiedzi (gniazda ESTAB).
# Przyczyna: runner `llama-server` umarl, a `ollama serve` zachowal wpis modelu.
# Detektor czytal TYLKO tekst `/api/ps` (deklaracja) — czyli mierzyl zamiar
# zamiast stanu. Teraz deklaracja jest KONFRONTOWANA z VRAM procesow ollama.
# Uwaga na role wartosci: `ollama ps` = DEKLARACJA, `nvidia-smi` = POMIAR.
if command -v nvidia-smi >/dev/null 2>&1; then
  _GPU_VRAM=$(nvidia-smi --query-compute-apps=process_name,used_memory --format=csv,noheader,nounits 2>/dev/null \
    | awk -F', ' 'tolower($1) ~ /ollama|llama-server/ {gsub(/[^0-9]/,"",$2); s+=$2} END {print s+0}')
  if [ "${RESIDENT:-0}" -ge 1 ] && [ "${_GPU_VRAM:-0}" -le 0 ]; then
    FAILS="$FAILS | GHOST: ollama deklaruje rezydentny model, ale nvidia-smi widzi ${_GPU_VRAM:-0} MiB procesow ollama (pasmo GPU MARTWE — runner umarl, wpis zostal). Naprawa: systemctl restart ollama; pomiar: scripts/aigon-gpu-lane-watchdog.sh"
  fi
  # 0 rezydentnych na wezle z GPU = WARN (stan przejsciowy po restarcie/idle),
  # NIE PASS — "brak dowodu" nie jest tym samym co "zdrowy".
  if [ "${RESIDENT:-0}" -eq 0 ]; then
    WARNS="$WARNS | pasmo GPU bez rezydentnego modelu (VRAM=${_GPU_VRAM:-0} MiB) — uruchom scripts/aigon-gpu-lane-watchdog.sh (nagrzewa kanoniczny model)"
  fi
fi

# ── 3. Rejestr: duże wpisy (>6 GB) poza Huihui → FAIL ─────────────────
while IFS= read -r line; do
  case "$line" in
    NAME*) continue ;;
    "") continue ;;
  esac
  lname=$(echo "$line" | awk '{print $1}')
  lid=$(echo "$line" | awk '{print $2}')
  lsize=$(echo "$line" | awk '{print $3}')
  lunit=$(echo "$line" | awk '{print $4}')
  [ "$lunit" = "GB" ] || continue
  lsize_gb=$(echo "$lsize" | cut -d. -f1)
  [ "${lsize_gb:-0}" -ge 6 ] || continue
  if ! is_allowed_big "$lid"; then
    FAILS="$FAILS | rejestr '$lname' (${lsize}) — wycofany/duży poza Huihui (ollama rm)"
  fi
done <<< "$LIST_OUT"

# ── 4. Churn: wycofane wagi (qwythos-27b/9b) ładowane w ostatnich 10 min ──
JOURNAL="${AIGON_G1M_JOURNAL:-$(journalctl -u ollama --since '10 min ago' --no-pager 2>/dev/null)}"
if [ -n "$JOURNAL" ]; then
  qw_loads=$(echo "$JOURNAL" | grep -cE "$QW_BLOB" 2>/dev/null || true)
  if [ "${qw_loads:-0}" -gt 0 ]; then
    FAILS="$FAILS | $qw_loads ew(e)nt(y) ładowania WYCOFANYCH wag qwythos (blob $QW_BLOB) w logach ollamy (10 min)"
  fi
fi

if [ -n "$FAILS" ]; then
  echo "FAIL gpu-one-model:$FAILS"
  echo "Fix (kanon 2026-09-24): dozwolone duze ID = Huihui-30B zachowany (70a25ee18ddc/d66bec0c51d8) ORAZ wagi gpt-oss-20b MXFP4 pod trzema nazwami (5645a529b160/95bfcd614539/434456081734); rezydentny ma byc DOKLADNIE JEDEN; wycofane (qwythos-27b/9b, heretic, ManniX-*, qwen3-coder:30b) usun: ollama rm; szczegoly: tools/gates/gpu-one-model.sh."
  exit 1
fi
[ -n "$WARNS" ] && echo "WARN gpu-one-model:$WARNS" && exit 2
echo "PASS gpu-one-model (GPU: DOKLADNIE JEDEN duzy model rezydentny — kanon 2026-09-24: gpt-oss-20b-abliterated MXFP4; brak wycofanych wag i churnu)"
exit 0

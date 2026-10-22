#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/llm-timeout-consistency.sh — gate llm-timeout-consistency
#
#  PO CO (incydent 2026-09-30, zmierzony): łańcuch timeoutów LLM był ROZJAZDNY
#  i to on — nie kod — blokował zarobek MONAI:
#    • runtime/config/standalone.yaml response_timeout_ms=900000 (15 min)
#      → GATE-046 ustawia z tego AIGON_REQUEST_TIMEOUT_SECS=900
#    • config/agent-models.yaml agent_env.AIGON_RUNTIME_TIMEOUT=900000
#      → sync do ~/.qwen/.env + ~/.bashrc
#    • MONAI bridge httpx.Timeout=300 (per-request)
#  Efekt zmierzony: 7 równoległych curl z `-m 900` trzymało slot GPU tak długo,
#  że runtime :38080 zwracał 500/502 INNYM klientom, a pętla bidera MONAI
#  czekała 300 s × 10 jobów — oferta NIGDY nie dochodziła do wysłania
#  (0 potwierdzonych bidów w całej historii). Po dostrojeniu: bid 495694087
#  POTWIERDZONY na Freelancerze.
#
#  CO MIERZY (nie zgaduje):
#    1. Są TYLKO DWA autorytatywne źródła timeoutu runtime:
#       standalone.yaml (response_timeout_ms) i agent-models.yaml (agent_env).
#    2. Ich wartości są w OKNIE 60 s .. 600 s. Poniżej 60 s ucina realną
#       generację (zmierzone: 500 tok = 34 s → zimny load + narzut > 60 s
#       potrafi przekroczyć); powyżej 600 s wraca klasa „wiszące żądanie
#       trzyma GPU na kwadrans".
#    3. Dystrybucja zgadza się z SSOT: ~/.qwen/.env ORAZ ~/.bashrc mają tę
#       samą wartość co agent_env (kanon 2026-08-13: sync_agent_env pisze do obu;
#       rozjazd .env vs .bashrc = agent na innej wartości niż deklaruje SSOT).
#    4. Bramka na regresję klasy: ŻADNE z tych źródeł nie wraca do ≥900000 ms
#       (=900 s) bez świadomej decyzji (którą znaczy się tu, w tym pliku).
#
#  Kontrakt z hook-runner.sh:
#    exit 0 = PASS (spójne i w oknie)
#    exit 1 = FAIL (rozjazd / poza oknem / regresja 900 s)
#    exit 2 = błąd środowiska (brak plików SSOT / brak yaml parsera)
#  Opcje: --json → raport JSON na stdout
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="${AIGON_ROOT:-/opt/PROD}"
# HOME_OPER — dom OPERATORA (SSOT), niezależny od wołającego (root/aigon/sniegul).
# $HOME dawał FAŁSZYWA CZERWIEŃ: reaktor (root, HOME=/root) nie widział ~/.qwen ani
# ~/.bashrc operatora -> „brak AIGON_RUNTIME_TIMEOUT" mimo zdrowego SSOT.
HOME_OPER="${AIGON_OPER_HOME:-/home/sniegul}"
STANDALONE="$ROOT/runtime/config/standalone.yaml"
AGENT_MODELS="$ROOT/config/agent-models.yaml"
QWEN_ENV="$HOME_OPER/.qwen/.env"
BASHRC="$HOME_OPER/.bashrc"

JSON=0
for a in "$@"; do
  case "$a" in --json) JSON=1 ;; esac
done

# Okno dopuszczalne (ms) — uzasadnione pomiarem w nagłówku.
FLOOR_MS=60000
CEIL_MS=600000
REGRESSION_MS=900000   # 900 s = klasa defektu 2026-09-30

fail() { echo "$*" >&2; [ "$JSON" = 1 ] && echo "{\"gate\":\"llm-timeout-consistency\",\"status\":\"FAIL\",\"detail\":\"$*\"}"; exit 1; }

[ -f "$STANDALONE" ]  || fail "brak SSOT: $STANDALONE"
[ -f "$AGENT_MODELS" ] || fail "brak SSOT: $AGENT_MODELS"

# Parser YAML — jeden punkt (python3 + pyyaml), jak reszta bramek.
python3 - "$STANDALONE" "$AGENT_MODELS" "$QWEN_ENV" "$BASHRC" "$FLOOR_MS" "$CEIL_MS" "$REGRESSION_MS" "$JSON" <<'PY'
import sys, os, re
standardalone, agent_models, qenv, bashrc, floor_ms, ceil_ms, regress_ms, as_json = sys.argv[1:]
floor_ms, ceil_ms, regress_ms = int(floor_ms), int(ceil_ms), int(regress_ms)
problems, notes = [], []

try:
    import yaml
except Exception as e:
    print(f"llm-timeout-consistency: BRAK pyyaml ({e}) — nie mogę sparsować SSOT", file=sys.stderr)
    sys.exit(2)

# ── 1+2. standalone.yaml → response_timeout_ms ──────────────────────────
try:
    sd = yaml.safe_load(open(standardalone, encoding="utf-8"))
    rt = sd["performance"]["response_timeout_ms"]
except Exception as e:
    print(f"llm-timeout-consistency: nie odczytalem response_timeout_ms: {e}", file=sys.stderr)
    sys.exit(2)
notes.append(f"standalone.response_timeout_ms={rt}ms")
if not isinstance(rt, int):
    problems.append(f"response_timeout_ms nie jest liczba: {rt!r}")
elif rt >= regress_ms:
    problems.append(f"REGRESJA: response_timeout_ms={rt}ms >= {regress_ms}ms (powrot klasy 900 s)")
elif not (floor_ms <= rt <= ceil_ms):
    problems.append(f"response_timeout_ms={rt}ms poza oknem {floor_ms}..{ceil_ms}ms")

# ── 3. agent-models.yaml → agent_env.*timeout* ──────────────────────────
try:
    am = yaml.safe_load(open(agent_models, encoding="utf-8"))
    aenv = am.get("agent_env") or {}
except Exception as e:
    print(f"llm-timeout-consistency: nie odczytalem agent_env: {e}", file=sys.stderr)
    sys.exit(2)

runtime_to = aenv.get("AIGON_RUNTIME_TIMEOUT")
api_to = aenv.get("AIGON_API_TIMEOUT")
for name, raw in (("AIGON_RUNTIME_TIMEOUT", runtime_to), ("AIGON_API_TIMEOUT", api_to)):
    if raw is None:
        problems.append(f"brak agent_env.{name}")
        continue
    val = int(raw)
    notes.append(f"agent_env.{name}={val}ms")
    if val >= regress_ms:
        problems.append(f"REGRESJA: {name}={val}ms >= {regress_ms}ms")
    elif not (floor_ms <= val <= ceil_ms):
        problems.append(f"{name}={val}ms poza oknem {floor_ms}..{ceil_ms}ms")

# ── 4. dystrybucja == SSOT (oba miejsca z kanonu 2026-08-13) ────────────
def read_kv(path, key):
    if not os.path.exists(path):
        return None
    for line in open(path, encoding="utf-8", errors="replace"):
        m = re.search(rf'\b{re.escape(key)}\b\s*=\s*"?(\d+)"?', line)
        if m:
            return int(m.group(1))
    return None

for path, label in ((qenv, "~/.qwen/.env"), (bashrc, "~/.bashrc")):
    if not os.path.exists(path):
        notes.append(f"{label}: brak pliku (pomijam — swiezy home)")
        continue
    got = read_kv(path, "AIGON_RUNTIME_TIMEOUT")
    if got is None:
        problems.append(f"{label}: brak AIGON_RUNTIME_TIMEOUT (sync nie dotarl?)")
    elif runtime_to is not None and got != int(runtime_to):
        problems.append(f"ROZJAZD: {label} AIGON_RUNTIME_TIMEOUT={got} != SSOT {runtime_to}")

if as_json == "1":
    import json
    print(json.dumps({
        "gate": "llm-timeout-consistency",
        "status": "FAIL" if problems else "PASS",
        "notes": notes, "problems": problems,
    }, ensure_ascii=False))
else:
    for n in notes:
        print(f"  {n}")
    if problems:
        for p in problems:
            print(f"  FAIL: {p}", file=sys.stderr)
        sys.exit(1)

sys.exit(1 if problems else 0)
PY

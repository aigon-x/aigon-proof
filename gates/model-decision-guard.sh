#!/usr/bin/env bash
# model-decision-guard.sh — egzekutor LAW-MODEL-DECISION-1.
#
# Prawo: żaden model nie jest domyślny. Wybór pochodzi wyłącznie z jawnej
# decyzji węzła (nodes.<node>.chains.<task_class>) w SSOT model-classifier.yaml.
# Węzeł nieznany albo łańcuch pusty = BLOCKED z dowodem, nigdy cichy default.
#
# Sprawdza CZTERY rzeczy (każda wykonywalnie):
#   C1 SSOT ma nodes i każdy węzeł ma niepusty chains (co najmniej jedna klasa).
#   C2 SSOT nie deklaruje globalnego defaultu (default_model/default/fallback_model).
#   C3 Klasyfikator istnieje i NIE wybiera modelu dla nieznanego węzła.
#   C4 Klasyfikator dla znanego węzła zwraca decyzję z niepustym łańcuchem.
#
# Kody: 0 PASS, 1 FAIL, 2 UNKNOWN (brak źródła — nie udajemy zieleni).
set -uo pipefail
ROOT="${AIGON_ROOT:-/opt/PROD}"
SSOT="$ROOT/config/canonical/model-classifier.yaml"
MC="$ROOT/tools/model-classifier/mc.py"

die() { echo "FAIL model-decision-guard: $*"; exit 1; }
unk() { echo "UNKNOWN model-decision-guard: $*"; exit 2; }

[ -f "$SSOT" ] || unk "brak SSOT $SSOT"
[ -f "$MC" ]   || unk "brak klasyfikatora $MC"
command -v python3 >/dev/null || unk "brak python3"

python3 - "$SSOT" "$MC" <<'PY'
import json, subprocess, sys, yaml

ssot_path, mc_path = sys.argv[1], sys.argv[2]
fails = []

try:
    doc = yaml.safe_load(open(ssot_path, encoding="utf-8")) or {}
except Exception as e:
    print(f"UNKNOWN model-decision-guard: SSOT nieparsowalny: {e}")
    raise SystemExit(2)

nodes = doc.get("nodes") or {}
if not isinstance(nodes, dict) or not nodes:
    fails.append("C1 SSOT nie ma sekcji nodes (brak decyzji per węzeł)")

for name, spec in nodes.items():
    if not isinstance(spec, dict):
        fails.append(f"C1 {name}: wpis węzła nie jest mapą")
        continue
    chains = spec.get("chains") or {}
    nonempty = [c for c, seq in chains.items() if isinstance(seq, list) and seq]
    if not nonempty:
        fails.append(f"C1 {name}: brak niepustego łańcucha dla żadnej klasy")

for bad in ("default_model", "default", "fallback_model", "defaults"):
    if bad in doc and doc.get(bad):
        fails.append(f"C2 SSOT deklaruje globalny default '{bad}' — prawo tego zakazuje")

def decide(node: str):
    p = subprocess.run([sys.executable, mc_path, "decide", "--node", node, "--prompt", "ping"],
                       capture_output=True, text=True, timeout=60)
    if p.returncode != 0:
        return None, f"rc={p.returncode} stderr={p.stderr.strip()[:160]}"
    try:
        return json.loads(p.stdout), None
    except Exception as e:
        return None, f"nieparsowalny JSON: {e}"

# C3: nieznany węzeł MUSI być BLOCKED, nie „pierwszy model z katalogu".
unknown, err = decide("__model_decision_guard_unknown__")
if err:
    fails.append(f"C3 nieznany węzeł: klasyfikator padł zamiast BLOCKED ({err})")
else:
    dec = unknown.get("decision") or {}
    chosen = dec.get("model") or dec.get("chosen") or dec.get("hop")
    status = str(dec.get("status") or "")
    reason = str(dec.get("reason") or "")
    blocked = (status.upper() in ("BLOCKED", "NO_DECISION", "UNSUPPORTED")
               or "block" in status.lower() or "block" in reason.lower()
               or "brak" in reason.lower())
    if chosen or not blocked:
        fails.append("C3 nieznany węzeł NIE jest BLOCKED — klasyfikator wybrał model domyślnie")

# C4: znany węzeł MUSI dać jawną decyzję.
known_ok = 0
for name in nodes:
    d, err = decide(name)
    if err:
        continue
    dec = d.get("decision") or {}
    chain = dec.get("chain") or dec.get("candidates") or dec.get("hops") or []
    chosen = dec.get("chosen") or dec.get("model") or dec.get("hop")
    if chosen and chain:
        known_ok += 1
if nodes and known_ok == 0:
    fails.append("C4 żaden znany węzeł nie zwrócił decyzji z modelem i łańcuchem")

if fails:
    for f in fails:
        print("FAIL model-decision-guard:", f)
    raise SystemExit(1)
print(f"PASS model-decision-guard: nodes={len(nodes)} decyzje_ok={known_ok} default=brak unknown=BLOCKED")
PY

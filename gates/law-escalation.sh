#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/law-escalation.sh — S3-T2 (deterministyczne progi eskalacji)
#
#  PRAWO: klasa autonomii akcji jest rozstrzygana DETERMINISTYCZNIE.
#  (a) żadna akcja nie występuje w dwóch klasach (auto/accept/forbidden) —
#      podwójny wpis = wynik zależny od kolejności czytania;
#  (b) reguła dla akcji NIESKLASYFIKOWANEJ jest MASZYNOWO czytelna
#      (klucz `escalation.unclassified` ∈ {accept, forbidden}), a nie
#      komentarzem — komentarza żaden egzekutor nie wykona;
#  (c) guardrails.mode == enforce.
#  Override: LAW_ESC_FILE. exit 0 = PASS, 1 = FAIL.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail
F="${LAW_ESC_FILE:-/srv/aigon/config/autonomy.yaml}"
python3 - "$F" <<'PY'
import sys, yaml
try: d = yaml.safe_load(open(sys.argv[1])) or {}
except Exception as e: print(f"[FAIL] nieczytelny {sys.argv[1]}: {e}"); sys.exit(1)
fail = 0
seen = {}
for cls in ("auto", "accept", "forbidden"):
    for grp, items in (d.get(cls) or {}).items():
        for it in items or []:
            for k in (it.keys() if isinstance(it, dict) else [it]):
                seen.setdefault(k, []).append(f"{cls}.{grp}")
dup = {k: v for k, v in seen.items() if len({x.split('.')[0] for x in v}) > 1}
if dup:
    fail = 1
    for k, v in dup.items(): print(f"[FAIL] akcja '{k}' w wielu klasach: {v}")
else:
    print(f"[PASS] {len(seen)} akcji, każda w dokładnie jednej klasie")
esc = d.get("escalation") if isinstance(d.get("escalation"), dict) else {}
u = esc.get("unclassified")
if u in ("accept", "forbidden"):
    print(f"[PASS] escalation.unclassified={u}")
else:
    fail = 1
    print(f"[FAIL] brak maszynowej reguły escalation.unclassified (jest: {u!r}) — "
          "zasada 'gdy niepewność — klasa wyższa' istnieje tylko jako komentarz")
mode = (d.get("guardrails") or {}).get("mode")
if mode == "enforce": print("[PASS] guardrails.mode=enforce")
else: fail = 1; print(f"[FAIL] guardrails.mode={mode!r} (wymagane enforce)")
print("law-escalation:", "FAIL" if fail else "PASS")
sys.exit(fail)
PY

#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/test_wired_check.sh — testy gate'a wired-check
#
#  Bez cargo, bez sieci — wyłącznie fixture katalogi + AIGON_WIRED_SRC.
#  Przypadki:
#    1. struct użyty (pole Runtime)          → PASS (exit 0)
#    2. struct nieużywany (martwy)           → FAIL (exit 1)
#    3. struct nieużywany, ale na allowliście → WARN (exit 0)
#    4. --regen odtwarza poprawny snapshot    → WARN (exit 0) + ważny JSON
#    5. brak katalogu src                     → NOT_APPLICABLE (exit 3, brak wejść)
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

GATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wired-check.sh"
[ -x "$GATE" ] || { echo "brak gate: $GATE"; exit 2; }

TMP="$(mktemp -d /tmp/wired-test.XXXXXX)"
PASS=0; FAILED=0

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

check() { # check <nazwa> <oczekiwany_rc> <oczekiwany_status> <raport_json>
  local name="$1" want_rc="$2" want_status="$3" report="$4"
  local rc=0 status=""
  rc=$(echo "$report" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("rc",0))' 2>/dev/null || echo "?")
  status=$(echo "$report" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("status","?"))' 2>/dev/null || echo "?")
  if [ "$rc" = "$want_rc" ] && [ "$status" = "$want_status" ]; then
    echo "PASS: $name (rc=$rc status=$status)"
    PASS=$((PASS+1))
  else
    echo "FAIL: $name (chciano rc=$want_rc status=$want_status, jest rc=$rc status=$status)"
    FAILED=$((FAILED+1))
  fi
}

# ── Przygotowanie fixture'ów ───────────────────────────────────────────
C1="$TMP/case1_used/src"; mkdir -p "$C1"
cat > "$C1/lib.rs" << 'EOF'
pub struct Runtime {
    pub comp: Widget,
}

pub fn make_runtime() -> Runtime {
    Runtime { comp: Widget::new() }
}
EOF
cat > "$C1/widget.rs" << 'EOF'
pub struct Widget {}

impl Widget {
    pub fn new() -> Self { Self {} }
}
EOF

C2="$TMP/case2_unused/src"; mkdir -p "$C2"
cat > "$C2/lib.rs" << 'EOF'
pub struct Runtime {
    pub seed: u32,
}

pub fn make_runtime() -> Runtime {
    Runtime { seed: 0 }
}
EOF
cat > "$C2/dead.rs" << 'EOF'
pub struct DeadThing {}
EOF

C3="$TMP/case3_allowlisted/src"; mkdir -p "$C3"
cp "$C2/lib.rs" "$C3/lib.rs"
cp "$C2/dead.rs" "$C3/dead.rs"
cat > "$C3/orphan_struct_audit.json" << 'EOF'
[{"name": "DeadThing", "file": "dead.rs", "line": 1, "reason": "known_external_contract"}]
EOF

C4="$TMP/case4_regen/src"; mkdir -p "$C4"
cp "$C2/lib.rs" "$C4/lib.rs"
cp "$C2/dead.rs" "$C4/dead.rs"

# ── Przypadek 1: struct użyty (pole Runtime) → PASS ────────────────────
R1=$(AIGON_WIRED_SRC="$C1" bash "$GATE" --json | python3 -c 'import json,sys;d=json.load(sys.stdin);d["rc"]=0;print(json.dumps(d))')
check "1. użyty struct → PASS" 0 PASS "$R1"

# ── Przypadek 2: struct nieużywany → FAIL (exit 1) ─────────────────────
R2=$(AIGON_WIRED_SRC="$C2" bash "$GATE" --json; echo "rc=$?")
R2=$(echo "$R2" | python3 -c '
import json,sys
lines=sys.stdin.read().splitlines()
rc=[l for l in lines if l.startswith("rc=")]
body="\n".join(l for l in lines if not l.startswith("rc="))
d=json.loads(body)
d["rc"]=int(rc[0][3:]) if rc else 99
print(json.dumps(d))')
check "2. nieużywany struct → FAIL" 1 FAIL "$R2"
echo "   (orphans_unjustified=$(echo "$R2" | python3 -c 'import json,sys;print(json.load(sys.stdin)["orphans_unjustified"])'), nazwa=$(echo "$R2" | python3 -c 'import json,sys;print(json.load(sys.stdin)["fail_orphans"][0]["name"])'))"

# ── Przypadek 3: nieużywany + allowlista → WARN (exit 0) ───────────────
R3=$(AIGON_WIRED_SRC="$C3" bash "$GATE" --json; echo "rc=$?")
R3=$(echo "$R3" | python3 -c '
import json,sys
lines=sys.stdin.read().splitlines()
rc=[l for l in lines if l.startswith("rc=")]
body="\n".join(l for l in lines if not l.startswith("rc="))
d=json.loads(body)
d["rc"]=int(rc[0][3:]) if rc else 99
print(json.dumps(d))')
check "3. allowlisted struct → WARN" 0 WARN "$R3"
echo "   (allowlisted=$(echo "$R3" | python3 -c 'import json,sys;print(json.load(sys.stdin)["orphans_allowlisted"])'), reason=$(echo "$R3" | python3 -c 'import json,sys;print(json.load(sys.stdin)["warn_orphans"][0]["reason"])'))"

# ── Przypadek 4: --regen odtwarza snapshot (korupcja → ważny JSON) ─────
AIGON_WIRED_SRC="$C4" bash "$GATE" --regen >/dev/null 2>&1
RC4A=$?
AUDIT_OK=$(python3 -c "
import json
json.load(open('$C4/orphan_struct_audit.json'))
print('json_ok')" 2>/dev/null || echo "json_broken")
if [ "$RC4A" = "1" ] && [ "$AUDIT_OK" = "json_ok" ]; then
  echo "PASS: 4a. --regen zapisał ważny JSON snapshot (rc=$RC4A, orphan dalej FAIL do czasu review)"
  PASS=$((PASS+1))
else
  echo "FAIL: 4a. --regen — rc=$RC4A, snapshot=$AUDIT_OK"
  FAILED=$((FAILED+1))
fi
# po regenie ten sam struct jest na allowliście → WARN (exit 0)
R4b=$(AIGON_WIRED_SRC="$C4" bash "$GATE" --json; echo "rc=$?")
R4b=$(echo "$R4b" | python3 -c '
import json,sys
lines=sys.stdin.read().splitlines()
rc=[l for l in lines if l.startswith("rc=")]
body="\n".join(l for l in lines if not l.startswith("rc="))
d=json.loads(body)
d["rc"]=int(rc[0][3:]) if rc else 99
print(json.dumps(d))')
check "4b. po --regen struct → WARN" 0 WARN "$R4b"

# ── Przypadek 5: brak katalogu src → NOT_APPLICABLE (exit 3) ───────────
# Kontrakt: brak WEJŚĆ to NOT_APPLICABLE (3), nie ERROR (2) — gate nie ma
# czego mierzyć, a to nie jest błąd wykonania. Spójne z evidence.sh, który
# mapuje 3 → NOT_APPLICABLE i z rejestrem bramek.
R5=$(AIGON_WIRED_SRC="$TMP/nie-ma-takiego-dir" bash "$GATE" --quiet; echo "rc=$?")
RC5=$(echo "$R5" | grep -oP 'rc=\K[0-9]+' || echo "?")
if [ "$RC5" = "3" ]; then
  echo "PASS: 5. brak src → exit 3 (NOT_APPLICABLE — brak wejść)"
  PASS=$((PASS+1))
else
  echo "FAIL: 5. brak src → exit 3 (jest rc=$RC5)"
  FAILED=$((FAILED+1))
fi

# ── Podsumowanie ───────────────────────────────────────────────────────
echo "────────────────────────────────────────────"
echo "WYNIK: $PASS pass, $FAILED fail"
[ "$FAILED" -eq 0 ] || exit 1
exit 0

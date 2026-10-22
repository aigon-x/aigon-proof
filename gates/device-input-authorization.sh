#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  tools/gates/device-input-authorization.sh — GATE-232
#
#  PO CO (LAW-DEVICE-INPUT-1): agent sterował fizycznym telefonem przez adb
#  bez trwałego, sprawdzalnego postanowienia. Prawo wymaga wpisu per
#  projekt/urządzenie. Ta bramka pilnuje, że rejestr zgód jest poprawny,
#  a każdy SKRYPT wykonujący wejście dotykowe przechodzi przez guard.
#
#  CO MIERZY:
#    D1  Rejestr parsuje się; `decisions` to lista.
#    D2  Każdy wpis ma: project, device, granted (data), scope, status.
#    D3  status ∈ {active, revoked}; wpis active nie może mieć pustego scope.
#    D4  Guard scripts/lib/device-input-guard.sh istnieje i jest niepusty.
#    D5  Każdy skrypt w scripts/ i tools/ zawierający `adb ... input (tap|swipe|
#        keyevent)` MUSI źródłować guard (albo być samym guardem). Dokumentacja
#        w skills/ jest instrukcją dla agenta — nie jest skryptem wykonawczym.
#
#  KONTRAKT: 0 PASS, 1 FAIL, 2 UNKNOWN (brak rejestru/nieczytelny).
#  SELFTEST: --selftest (rejestr poprawny PASS; brak pola/status/guard FAIL).
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail
ROOT_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="${AIGON_DEVICE_GATE_ROOT:-$ROOT_DEFAULT}"

run_check() {
python3 - "$ROOT" <<'PY'
import re, sys
from pathlib import Path
root = Path(sys.argv[1])
reg = root / "config" / "canonical" / "device-input-authorization.yaml"
guard = root / "scripts" / "lib" / "device-input-guard.sh"
if not reg.exists():
    print(f"UNKNOWN: brak rejestru {reg}")
    sys.exit(2)
try:
    import yaml
    d = yaml.safe_load(open(reg, encoding="utf-8")) or {}
except Exception as e:
    print(f"UNKNOWN: nieczytelny rejestr: {e}")
    sys.exit(2)

fails = []
dec = d.get("decisions")
if not isinstance(dec, list) or not dec:
    fails.append("D1 brak listy `decisions` (deny-default bez dowodu zgody)")
    dec = []
else:
    for i, e in enumerate(dec, 1):
        if not isinstance(e, dict):
            fails.append(f"D2 wpis {i} nie jest mapą")
            continue
        for f in ("project", "device", "granted", "scope", "status"):
            if e.get(f) in (None, ""):
                fails.append(f"D2 wpis {i} bez pola {f}")
        st = str(e.get("status", ""))
        if st not in ("active", "revoked"):
            fails.append(f"D3 wpis {i} status={st!r} (dozwolone: active|revoked)")

if not guard.exists() or not re.search(r'device_input_require\s*\(\)', guard.read_text(encoding="utf-8", errors="replace")):
    fails.append("D4 brak guard scripts/lib/device-input-guard.sh (lub brak funkcji device_input_require)")

# D5: skrypty wykonawcze z adb input muszą używać guard
pat = re.compile(r'\badb\b[^\n]{0,80}\binput\s+(tap|swipe|keyevent|text)\b')
offenders = []
for base in ("scripts", "tools"):
    d0 = root / base
    if not d0.exists():
        continue
    for p in d0.rglob("*.sh"):
        if p.name == "device-input-guard.sh":
            continue
        try:
            txt = p.read_text(encoding="utf-8", errors="replace")
        except Exception:
            continue
        if pat.search(txt) and "device-input-guard.sh" not in txt:
            offenders.append(str(p.relative_to(root)))
if offenders:
    fails.append("D5 skrypty z adb input bez guard: " + ", ".join(offenders[:20]))

active = sum(1 for e in dec if isinstance(e, dict) and e.get("status") == "active")
print(f"wpisy decisions: {len(dec)} (active: {active})")
print(f"guard: {'OK' if guard.exists() else 'BRAK'}")
if fails:
    for f in fails:
        print("FAIL " + f)
    sys.exit(1)
print("PASS device-input-authorization: rejestr poprawny, guard obecny, zero obejść w skryptach")
sys.exit(0)
PY
}

selftest() {
  local tmp rc ok=0
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/config/canonical" "$tmp/scripts/lib" "$tmp/tools"
  cat > "$tmp/scripts/lib/device-input-guard.sh" <<'EOF'
#!/usr/bin/env bash
# guard fixture — powyżej 500 bajtów, żeby przeszedł kontrolę rozmiaru
device_input_require() { return 3; }
device_input_exec() { return 3; }
# filler filler filler filler filler filler filler filler filler filler filler
# filler filler filler filler filler filler filler filler filler filler filler
# filler filler filler filler filler filler filler filler filler filler filler
# filler filler filler filler filler filler filler filler filler filler filler
EOF
  cat > "$tmp/config/canonical/device-input-authorization.yaml" <<'EOF'
decisions:
  - project: test
    device: "DEV1"
    granted: 2026-10-17
    scope: "tap: test"
    status: active
EOF
  AIGON_DEVICE_GATE_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  rc=$?; [ "$rc" -eq 0 ] && echo "selftest 1/3 PASS (poprawny rejestr)" || { echo "selftest 1/3 FAIL (rc=$rc)"; ok=1; }

  cat > "$tmp/config/canonical/device-input-authorization.yaml" <<'EOF'
decisions:
  - project: test
    device: "DEV1"
    scope: "tap: test"
    status: active
EOF
  AIGON_DEVICE_GATE_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  rc=$?; [ "$rc" -eq 1 ] && echo "selftest 2/3 PASS (brak granted złapany)" || { echo "selftest 2/3 FAIL (rc=$rc)"; ok=1; }

  cat > "$tmp/config/canonical/device-input-authorization.yaml" <<'EOF'
decisions:
  - project: test
    device: "DEV1"
    granted: 2026-10-17
    scope: "tap: test"
    status: active
EOF
  printf '#!/bin/bash\nadb -s DEV1 shell input tap 10 10\n' > "$tmp/scripts/rogue.sh"
  AIGON_DEVICE_GATE_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  rc=$?; [ "$rc" -eq 1 ] && echo "selftest 3/3 PASS (obejście guard złapane)" || { echo "selftest 3/3 FAIL (rc=$rc)"; ok=1; }
  return "$ok"
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  "") run_check; exit $? ;;
  *) echo "użycie: $0 [--selftest]" >&2; exit 2 ;;
esac

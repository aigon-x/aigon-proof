#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/capability-parity.sh — parytet ACCESS PLANE ↔ RUNTIME MANIFEST
#
#  PO CO (2026-10-21, strumień S1 „akceleratory"):
#    Akcje produktu były zadeklarowane WYŁĄCZNIE w pliku adnotacyjnym
#    runtime/manifests/capabilities-extra-c340-c464.yaml, którego loader NIE
#    czyta (ManifestSet czyta tylko `entries:`). Efekt zmierzony audytem:
#    0 wpisów akceleratorów w config/canonical/capabilities.yaml i brak akcji
#    w realnym rejestrze runtime — czyli brak capability = DENY, a nie
#    „słabsza kontrola". Ten gate pilnuje, żeby ten rozjazd nie wrócił:
#    KAŻDA akcja z access plane ma wpis w runtime manifest i ODWROTNIE.
#
#  ZAKRES: domyślnie rodzina `akceleratory` (env AIGON_PARITY_PREFIX).
#    Access plane:  config/canonical/capabilities.yaml → capabilities[].id
#                   (id w postaci `<prefix>.<action>`)
#    Runtime:       runtime/manifests/capabilities.yaml → entries[].name
#                   (name w postaci `<prefix>:<action>`; kropka też akceptowana)
#    Wpis samego kernela `<prefix>` (bez akcji) NIE jest akcją i jest ignorowany.
#
#  KONTRAKT: exit 0 = PASS (zbiory równe, oba niepuste)
#            exit 1 = FAIL (brak wpisu po którejkolwiek stronie, plik nieczytelny,
#                           pusty zbiór po jednej stronie — brak podstawy pomiaru)
#
#  UŻYCIE:
#    tools/gates/capability-parity.sh
#    tools/gates/capability-parity.sh --selftest   # pozytywny + 3 negatywne
#    AIGON_PARITY_PREFIX=monai tools/gates/capability-parity.sh
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 1
CANON="${AIGON_CANONICAL_CAPS:-$ROOT/config/canonical/capabilities.yaml}"
RUNTIME="${AIGON_RUNTIME_CAPS:-$ROOT/runtime/manifests/capabilities.yaml}"
PREFIX="${AIGON_PARITY_PREFIX:-akceleratory}"

compare() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
import yaml

canon_path, runtime_path, prefix = sys.argv[1:4]


def load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return yaml.safe_load(fh) or {}
    except FileNotFoundError:
        print(f"FAIL: brak pliku {path}")
        sys.exit(1)
    except Exception as exc:  # YAML/IO — nie ma podstawy do PASS
        print(f"FAIL: nie czytam {path}: {exc}")
        sys.exit(1)


canon_raw = load(canon_path)
runtime_raw = load(runtime_path)

canon = {}
for entry in canon_raw.get("capabilities") or []:
    if not isinstance(entry, dict):
        continue
    cid = str(entry.get("id") or "")
    if cid.startswith(prefix + "."):
        action = cid.split(".", 1)[1]
        if action:
            canon[action] = cid

runtime = {}
for entry in runtime_raw.get("entries") or []:
    if not isinstance(entry, dict):
        continue
    name = str(entry.get("name") or "")
    if name.startswith(prefix + ":"):
        action = name.split(":", 1)[1]
    elif name.startswith(prefix + "."):
        action = name.split(".", 1)[1]
    else:
        continue  # kernel `<prefix>` bez akcji albo inna rodzina
    if action:
        runtime[action] = name

missing_runtime = sorted(set(canon) - set(runtime))
missing_access = sorted(set(runtime) - set(canon))

print(
    "PARITY-SUMMARY prefix=%s canonical=%d runtime=%d missing_runtime=%d missing_access=%d"
    % (prefix, len(canon), len(runtime), len(missing_runtime), len(missing_access))
)
for action in missing_runtime:
    print(f"  [MISSING-RUNTIME] {prefix}.{action} — jest w access plane, brak w runtime entries")
for action in missing_access:
    print(f"  [MISSING-ACCESS] {prefix}:{action} — jest w runtime entries, brak w access plane")

if not canon or not runtime:
    print("FAIL: pusty zbiór po jednej stronie — brak podstawy pomiaru (nie PASS)")
    sys.exit(1)

sys.exit(0 if not missing_runtime and not missing_access else 1)
PY
}

if [ "${1:-}" = "--selftest" ]; then
  echo "── SELFTEST capability-parity ──"
  TMP="$(mktemp -d)" || { echo "FAIL: mktemp"; exit 1; }
  trap 'rm -rf "$TMP"' EXIT
  FAILS=0

  cat > "$TMP/canon_good.yaml" <<'YAML'
capabilities:
  - id: akceleratory.scan
  - id: akceleratory.outreach_send
YAML

  cat > "$TMP/runtime_good.yaml" <<'YAML'
entries:
  - name: akceleratory
    backend: kernel
  - name: akceleratory:scan
  - name: akceleratory:outreach_send
YAML

  # negatywny 1: akcja w access plane bez wpisu w runtime
  cat > "$TMP/runtime_missing.yaml" <<'YAML'
entries:
  - name: akceleratory:scan
YAML

  # negatywny 2: wpis w runtime bez akcji w access plane
  cat > "$TMP/canon_missing.yaml" <<'YAML'
capabilities:
  - id: akceleratory.scan
YAML

  # negatywny 3: pusty access plane (brak podstawy pomiaru)
  cat > "$TMP/canon_empty.yaml" <<'YAML'
capabilities: []
YAML

  run_case() {
    local opis="$1" oczekiwany="$2" canon="$3" runtime="$4"
    local out rc
    out="$(compare "$canon" "$runtime" akceleratory 2>&1)"
    rc=$?
    if [ "$rc" -eq "$oczekiwany" ]; then
      echo "  [OK]   $opis → exit=$rc (oczekiwany $oczekiwany)"
    else
      echo "  [FAIL] $opis → exit=$rc (oczekiwany $oczekiwany)"
      printf '%s\n' "$out" | sed 's/^/         /'
      FAILS=$((FAILS + 1))
    fi
  }

  run_case "pozytywny: zbiory równe" 0 "$TMP/canon_good.yaml" "$TMP/runtime_good.yaml"
  run_case "negatywny: brak wpisu w runtime" 1 "$TMP/canon_good.yaml" "$TMP/runtime_missing.yaml"
  run_case "negatywny: nadmiarowy wpis w runtime" 1 "$TMP/canon_missing.yaml" "$TMP/runtime_good.yaml"
  run_case "negatywny: pusty access plane" 1 "$TMP/canon_empty.yaml" "$TMP/runtime_good.yaml"
  run_case "negatywny: brak pliku runtime" 1 "$TMP/canon_good.yaml" "$TMP/nie_ma.yaml"

  if [ "$FAILS" -eq 0 ]; then
    echo "PASS capability-parity --selftest (5/5 przypadków zgodnych z oczekiwaniem)"
    exit 0
  fi
  echo "FAIL capability-parity --selftest ($FAILS przypadków niezgodnych)"
  exit 1
fi

OUT="$(compare "$CANON" "$RUNTIME" "$PREFIX" 2>&1)"
RC=$?
printf '%s\n' "$OUT"
SUMMARY="$(printf '%s' "$OUT" | grep '^PARITY-SUMMARY ' | tail -1)"

if [ "$RC" -eq 0 ]; then
  echo "PASS capability-parity (${SUMMARY#PARITY-SUMMARY }; access plane == runtime manifest, ${CANON##*/} ↔ ${RUNTIME##*/})"
  exit 0
fi
echo "FAIL capability-parity (${SUMMARY:-brak pomiaru}; akcja bez wpisu po którejkolwiek stronie = DENY, nie PASS)"
exit 1

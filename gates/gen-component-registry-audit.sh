#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/gen-component-registry-audit.sh — generator snapshota
#  component_registry_audit.json (dla gate tick-wiring)
#
#  Tworzy artefakt JSON: component_registry_audit.json — spis komponentów
#  zarejestrowanych w ComponentRegistry (setup_components w lib.rs) oraz
#  kerneli z KernelManager z informacją, czy mają implementację `impl
#  Kernel for`. Analiza STATYCZNA (grep/regex, python3), bez cargo — szybka
#  i bezpieczna w hooku. Ta sama logika co sekcje 1-2 w tick-wiring.sh.
#
#  Wyjście:  $ROOT/artifacts/gates/component_registry_audit.json
#            (fallback: /tmp/component_registry_audit.json gdy brak praw)
#  Idempotentny — nadpisuje poprzedni snapshot.
#
#  Zmienne env do testów: AIGON_TW_LIB (lib.rs), AIGON_TW_CRATES (katalog
#  crates), AIGON_CRA_OUT (ścieżka wyjściowa snapshotu).
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${AIGON_TW_LIB:-$ROOT/runtime/crates/aigon-runtime/src/lib.rs}"
CRATES="${AIGON_TW_CRATES:-$ROOT/runtime/crates}"
OUT="${AIGON_CRA_OUT:-$ROOT/artifacts/gates/component_registry_audit.json}"

[ -f "$LIB" ] || { echo "gen-component-registry-audit: brak $LIB"; exit 1; }
[ -d "$CRATES" ] || { echo "gen-component-registry-audit: brak $CRATES"; exit 1; }

SNAPSHOT="$(LIB="$LIB" CRATES="$CRATES" python3 - << 'PYEOF'
import json, os, re, sys
from datetime import datetime, timezone

lib = os.environ["LIB"]
crates = os.environ["CRATES"]

# ── 1. Komponenty z setup_components (ComponentId + register_comp!) ────
components = []
found_setup = False
try:
    with open(lib, "r", encoding="utf-8", errors="replace") as f:
        lines = f.readlines()
except OSError as e:
    print(json.dumps({"status": "ENV", "error": str(e)}, ensure_ascii=False))
    sys.exit(0)

in_setup = False
brace = 0
for ln in lines:
    if not found_setup and re.search(r"async fn setup_components", ln):
        found_setup = True
        in_setup = True
        brace = ln.count("{") - ln.count("}")
        continue
    if in_setup:
        brace += ln.count("{") - ln.count("}")
        m = re.search(r'ComponentId\("([a-z_0-9]+)"', ln)
        if m and m.group(1) not in components:
            components.append(m.group(1))
        m2 = re.search(r'register_comp!\("([a-z_0-9]+)"', ln)
        if m2 and m2.group(1) not in components:
            components.append(m2.group(1))
        if brace <= 0:
            break

# ── 2. Kernele z KernelManager (mgr.register(Box::new(..Kernel::new()))) ─
registered = []
for ln in lines:
    if "mgr.register(Box::new" not in ln:
        continue
    for m in re.finditer(r"([A-Z][A-Za-z0-9_]*)Kernel::", ln):
        name = m.group(1) + "Kernel"
        if name not in registered:
            registered.append(name)

# impl Kernel for — skan crates
impl_kernels = set()
for dirpath, dirnames, filenames in os.walk(crates):
    for fn in filenames:
        if not fn.endswith(".rs"):
            continue
        path = os.path.join(dirpath, fn)
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                txt = f.read()
        except OSError:
            continue
        for m in re.finditer(r"impl\s+(?:Kernel\s+for\s+)?([A-Z][A-Za-z0-9_]*Kernel)", txt):
            impl_kernels.add(m.group(1))
        for m in re.finditer(r"impl\s+(?:::\s*)?Kernel\s+for\s+([A-Z][A-Za-z0-9_]*Kernel)", txt):
            impl_kernels.add(m.group(1))

kernels = [
    {"name": name, "has_impl": name in impl_kernels}
    for name in registered
]
missing = sorted(set(registered) - impl_kernels)

snapshot = {
    "schema_version": "1.0",
    "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "gate": "tick-wiring",
    "setup_components_found": found_setup,
    "components": components,
    "count_components": len(components),
    "kernels": kernels,
    "count_kernels": len(kernels),
    "kernels_missing_impl": missing,
    "source_lib": lib,
}
print(json.dumps(snapshot, indent=2, ensure_ascii=False))
PYEOF
)" || { echo "gen-component-registry-audit: analiza nie powiodła się"; exit 1; }

# ── 3. Zapis snapshotu (artifacts/gates/, fallback /tmp) ───────────────
# Atomic: zapis do tymczasowego pliku + mv — mv wymaga tylko write na
# katalogu (nie na pliku docelowym), więc działa też gdy istniejący
# snapshot ma innego właściciela (np. przebieg jako aigon nadpisuje
# snapshot wygenerowany przez sniegul).
OUT_DIR="$(dirname "$OUT")"
mkdir -p "$OUT_DIR" 2>/dev/null || { OUT_DIR="/tmp"; OUT="/tmp/component_registry_audit.json"; mkdir -p "$OUT_DIR"; }

TMP_OUT="$OUT_DIR/.component_registry_audit.tmp.$$"
if ! printf '%s\n' "$SNAPSHOT" > "$TMP_OUT" 2>/dev/null || ! mv -f "$TMP_OUT" "$OUT" 2>/dev/null; then
  rm -f "$TMP_OUT" 2>/dev/null
  OUT="/tmp/component_registry_audit.json"
  TMP_OUT="$OUT.tmp.$$"
  printf '%s\n' "$SNAPSHOT" > "$TMP_OUT" 2>/dev/null && mv -f "$TMP_OUT" "$OUT" 2>/dev/null \
    || { rm -f "$TMP_OUT" 2>/dev/null; echo "gen-component-registry-audit: nie mogę zapisać snapshotu"; exit 1; }
fi

# Weryfikacja: JSON musi się parsować
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$OUT" 2>/dev/null \
  || { echo "gen-component-registry-audit: snapshot $OUT to niepoprawny JSON"; exit 1; }

echo "gen-component-registry-audit: snapshot zapisany do $OUT (komponenty=$(echo "$SNAPSHOT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["count_components"])') kernele=$(echo "$SNAPSHOT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["count_kernels"])'))"
exit 0

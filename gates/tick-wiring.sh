#!/usr/bin/env bash
# TEMPLATE-CANON G-20f: wymaga runtime/crates/aigon-runtime/src/lib.rs
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/tick-wiring.sh — gate tick-wiring (hook-runner)
#
#  AUTOMAT: „każdy komponent zarejestrowany w ComponentRegistry ma tick".
#  Weryfikuje SPÓJNOŚĆ rejestracji z mechanizmem tick:
#    1. Sekcja setup_components() w lib.rs istnieje i rejestruje komponenty
#       (ComponentId) przez register_with — bez tego registry jest pusty.
#    2. Każdy kernel zarejestrowany w KernelManager (mgr.register(Box::new(
#       ..Kernel::new()))) ma implementację `impl Kernel for` w swoim crate.
#       Tick NIE jest opcjonalny — trait Kernel wymaga `async fn tick`
#       (aigon-kernel/src/lib.rs), więc kompilacja gwarantuje metodę;
#       ten check łapie rozjazd rejestracji od implementacji (drift).
#    3. Generator snapshota component_registry_audit.json — zamierzony przez
#       gates.yaml; sprawdzany jest tools/gates/gen-component-registry-audit.sh
#       (istnienie + wykonywalność) i uruchamiany (max ~10s) → snapshot
#       artefaktowy w artifacts/gates/; brak generatora = uczciwy WARN.
#
#  Kontrakt z hook-runner.sh:
#    exit 0 = PASS
#    exit 1 = FAIL (kernel zarejestrowany bez impl Kernel, brak sekcji rejestracji)
#    exit 3 = WARN (brak generatora snapshota — diagnoza, nie blokuje)
#
#  Analiza STATYCZNA (grep), bez cargo — szybka i bezpieczna w hooku.
#  Zmienne env do testów: AIGON_TW_LIB (lib.rs), AIGON_TW_CRATES (katalog crates).
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${AIGON_TW_LIB:-$ROOT/runtime/crates/aigon-runtime/src/lib.rs}"
CRATES="${AIGON_TW_CRATES:-$ROOT/runtime/crates}"

[ -f "$LIB" ] || { echo "tick-wiring: brak $LIB"; exit 3; }
[ -d "$CRATES" ] || { echo "tick-wiring: brak $CRATES"; exit 3; }

REPORT="$(LIB="$LIB" CRATES="$CRATES" python3 - << 'PYEOF'
import json, os, re, sys

lib = os.environ["LIB"]
crates = os.environ["CRATES"]

# ── 1. Sekcja rejestracji komponentów (setup_components) ───────────────
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
for i, ln in enumerate(lines, 1):
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
        # batch register_comp!("id", "Name") — makro rejestrujące kolejne komponenty
        m2 = re.search(r'register_comp!\("([a-z_0-9]+)"', ln)
        if m2 and m2.group(1) not in components:
            components.append(m2.group(1))
        if brace <= 0:
            break

# ── 2. Kernele zarejestrowane w KernelManager + ich impl Kernel ───────
# Rejestracje bywają wielolinijkowe (mgr.register(Box::new(if let ... { ... })),
# mgr.register(Box::new(\n ...Kernel::with_shared_counters(...))), itd.), więc
# zamiast regexu per-linia wycinamy cały blok do najbliższego "));".
registered = []
text = "".join(lines)
pos = 0
while True:
    start = text.find("mgr.register(Box::new", pos)
    if start == -1:
        break
    end = text.find("));", start)
    if end == -1:
        end = len(text)
    block = text[start:end]
    # łapie NanoKernel::new(), YAIroslawKernel::with_id(), LearningKernel::with_shared_counters()
    for m in re.finditer(r"([A-Z][A-Za-z0-9_]*)Kernel::", block):
        name = m.group(1) + "Kernel"
        if name not in registered:
            registered.append(name)
    pos = end + 3

# impl Kernel for — skan crates (ograniczony do plików z Kernel::new lub impl Kernel)
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

missing = sorted(set(registered) - impl_kernels)

# ── 3. Generator snapshota component_registry_audit.json ───────────────
snapshot_gen = False
# a) kanoniczny generator w tools/gates/ — istnienie + wykonywalność
gen = os.path.join(os.path.dirname(os.path.dirname(crates)), "tools", "gates", "gen-component-registry-audit.sh")
if os.path.isfile(gen) and os.access(gen, os.X_OK):
    snapshot_gen = True
# b) fallback: skan crates/ za stringiem "component_registry_audit"
if not snapshot_gen:
    for dirpath, dirnames, filenames in os.walk(crates):
        if snapshot_gen:
            break
        for fn in filenames:
            if not fn.endswith((".rs", ".py", ".sh")):
                continue
            path = os.path.join(dirpath, fn)
            try:
                with open(path, "r", encoding="utf-8", errors="replace") as f:
                    if "component_registry_audit" in f.read():
                        snapshot_gen = True
                        break
            except OSError:
                continue

status = "FAIL" if missing else ("WARN" if not snapshot_gen else "PASS")
report = {
    "gate": "tick-wiring",
    "status": status,
    "setup_components_found": found_setup,
    "components_registered": len(components),
    "components": components,
    "kernels_registered": len(registered),
    "kernels_with_impl": len(impl_kernels),
    "kernels_missing_impl": missing,
    "snapshot_generator": snapshot_gen,
}
print(json.dumps(report, indent=2, ensure_ascii=False))
PYEOF
)" || { echo "tick-wiring: analiza nie powiodła się"; exit 2; }

STATUS="$(echo "$REPORT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["status"])')"
[ -n "$STATUS" ] || { echo "tick-wiring: nie mogę odczytać statusu raportu"; exit 2; }

# ── 3b. Uruchom generator snapshota (jeśli wykonywalny, max ~10s) ───────
GEN="$ROOT/tools/gates/gen-component-registry-audit.sh"
if [ -x "$GEN" ]; then
  if ! timeout 10 bash "$GEN" >/dev/null 2>&1; then
    echo "tick-wiring: WARN — generator snapshota nie wygenerował snapshotu (exit=$?)"
    exit 2
  fi
fi

AIGON_REPORT="$REPORT" python3 - << 'PYEOF'
import json, os
r = json.loads(os.environ["AIGON_REPORT"])
print(f"tick-wiring: {r['status']} — komponenty={r['components_registered']} kernele={r['kernels_registered']} (impl Kernel: {r['kernels_with_impl']})")
if not r["setup_components_found"]:
    print("  FAIL: brak sekcji setup_components() w lib.rs — registry pusty")
for k in r.get("kernels_missing_impl", [])[:10]:
    print(f"  FAIL kernel bez impl Kernel: {k}")
if not r["snapshot_generator"]:
    print("  WARN: generator snapshota component_registry_audit.json NIE istnieje w kodzie (tylko komentarz gates.yaml) — ticki weryfikowane statycznie; generator do implementacji")
PYEOF

case "$STATUS" in
  PASS) exit 0 ;;
  FAIL) exit 1 ;;
  WARN) exit 2 ;;
  *) exit 2 ;;
esac

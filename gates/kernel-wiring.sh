#!/usr/bin/env bash
# kernel-wiring.sh — GATE: spójność rejestracji kerneli (manifest ↔ kod ↔ crate).
# Kontrakt hook-runner: tools/gates/<id>.sh, exit 0=PASS 1=FAIL 2=env.
#
# ROZKAZ SUWERENA 2026-10-02: „zastanów się jak stworzyć bramkę, że jak dodajemy
# kernela to przy gejcie sprawdzić wszystko czy wszystko jest". Zmierzony problem:
# kernel można dodać na 3 sposoby (crate / manifest / rejestracja w lib.rs) i NIC
# nie wymusza ich spójności — zmierzone 2026-10-02:
#   - 8 wpisów manifestu bez rejestracji w kodzie (config, hermes, krono, ledger,
#     resilience, truth, world_model, writer),
#   - 4 crates bez wpisu w manifescie (homeostasis, prompt-builder, self-modify, world),
#   - 3 crates bez rejestracji (homeostasis, prompt-builder, self-modify),
#   - rozjazd nazwy: crate `world` vs manifest `world_model`.
#
# TA BRAMKA WYKRYWA KAŻDĄ Z TYCH KLAS. Nowy kernel MUSI być spójny w 3 miejscach:
#   1. crate runtime/crates/aigon-kernel-<name>/           (kod)
#   2. wpis w runtime/manifests/kernels.yaml               (deklaracja: enabled/tick/domain)
#   3. rejestracja w aigon-runtime/src/lib.rs (mgr.register) (żywe podpięcie)
# Reguły:
#   - crate bez manifestu        = FAIL (kernel w kodzie bez deklaracji)
#   - crate bez rejestracji      = FAIL (kernel napisany, nie podpięty = martwy)
#   - manifest bez crate i kodu  = FAIL (deklaracja bez implementacji = fikcja)
#   - kod bez manifestu          = FAIL (rejestracja bez deklaracji)
# Wyjątki (znany dług) w tools/gates/kernel-wiring-allowlist.txt — wolno TYLKO zmniejszać.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST="$ROOT/runtime/manifests/kernels.yaml"
LIBRS="$ROOT/runtime/crates/aigon-runtime/src/lib.rs"
CRATES_DIR="$ROOT/runtime/crates"
ALLOW="$ROOT/tools/gates/kernel-wiring-allowlist.txt"

[ -f "$MANIFEST" ] || { echo "kernel-wiring: SKIP — brak $MANIFEST (env)"; exit 2; }
[ -f "$LIBRS" ] || { echo "kernel-wiring: SKIP — brak $LIBRS (env)"; exit 2; }

# Auto-wykrywanie kerneli (uwaga: heredoc z __PYKERNEL__, żeby nie kolidować z bash).
OUT=$(python3 - "$ROOT" <<'__PYKERNEL__'
import sys, os, re, glob

root = sys.argv[1]
manifest = os.path.join(root, "runtime/manifests/kernels.yaml")
librs = os.path.join(root, "runtime/crates/aigon-runtime/src/lib.rs")

# 1. manifest
try:
    import yaml
    mf = set(e["name"] for e in (yaml.safe_load(open(manifest)) or {}).get("entries", [])
              if isinstance(e, dict) and e.get("name"))
except Exception as e:
    print("ERR manifest parse: %s" % e); sys.exit(0)

# 2. crates (katalogi aigon-kernel-*)
crates = set()
for d in glob.glob(os.path.join(root, "runtime/crates/aigon-kernel-*/")):
    n = os.path.basename(d.rstrip("/")).replace("aigon-kernel-", "")
    crates.add(n)

# 3. rejestracja w lib.rs — KAZDA konwencja (FIX 2026-10-03, audyt: 8/12 fałszywych MANIFEST_BEZ_KODU):
#    a) aigon_kernel_<name>::        (crate aigon-kernel-<name>, np. aigon_kernel_writer::)
#    b) aigon_kernel::<name>_kernel:: (moduły w jednym crate, np. aigon_kernel::writer_kernel::)
#    c) aigon_<name>::*Kernel        (kernel w innym crate, np. aigon_krono::, aigon_resilience::)
src = open(librs).read()
code = set(re.findall(r"aigon_kernel_([a-z_]+)::", src))                    # (a)
# (b) moduł w crate aigon_kernel: aigon_kernel::<mod>:: (hermes, writer_kernel, config_kernel...)
code |= set(re.findall(r"aigon_kernel::([a-z_]+)::", src))
# (d) mgr.register(Box::new(<path>::<X>Kernel  → bierz przedostatni segment ścieżki jako nazwę
for m in re.findall(r"Box::new\(\s*([a-zA-Z0-9_:]+)::[A-Za-z]*Kernel", src):
    seg = m.split("::")
    if seg:
        code.add(seg[-1].replace("aigon_", ""))
# (c) aigon_<n>::...Kernel / aigon_<n>::kernel::XKernel
code |= set(re.findall(r"aigon_([a-z_]+)::(?:kernel::)?[A-Za-z]*Kernel", src))
# GLOBALNA normalizacja: zdejmij prefiks 'kernel_' ORAZ sufiks '_kernel'
code = {c[7:] if c.startswith("kernel_") else c for c in code}
code = {c[:-7] if c.endswith("_kernel") else c for c in code}
code.discard("kernel")  # samo 'kernel' = crate bazowy

# normalizacja: myślnik vs podkreślnik (crate `prompt-builder` == manifest `prompt_builder`)
norm = lambda s: s.replace("-", "_")
mf_n    = {norm(x): x for x in mf}
crates_n = {norm(x): x for x in crates}
code_n   = {norm(x): x for x in code}

allk = set(mf_n) | set(crates_n) | set(code_n)
fail = []

for k in sorted(allk):
    in_mf = k in mf_n
    in_cr = k in crates_n
    in_cd = k in code_n
    # crate bez manifestu
    if in_cr and not in_mf:
        fail.append("CRATE_BEZ_MANIFESTU %s" % crates_n[k])
    # crate bez rejestracji
    if in_cr and not in_cd:
        fail.append("CRATE_BEZ_REJESTRACJI %s" % crates_n[k])
    # manifest bez crate ORAZ bez kodu (deklaracja-fikcja)
    if in_mf and not in_cr and not in_cd:
        fail.append("MANIFEST_BEZ_KODU %s" % mf_n[k])
    # kod (rejestracja) bez manifestu
    if in_cd and not in_mf:
        fail.append("KOD_BEZ_MANIFESTU %s" % code_n[k])

for f in fail:
    print(f)
__PYKERNEL__
)

if [ -n "${OUT:-}" ] && printf '%s' "$OUT" | grep -q '^ERR manifest'; then
  echo "kernel-wiring: SKIP — $OUT (env)"; exit 2
fi

# Allowlist (znany dług, wolno tylko zmniejszać). FIX 2026-10-03: trymuj wiodące
# spacje z OUT — python drukuje "  KLASA nazwa", a allowlista jest bez wcięcia
# (grep -vxF wymaga DOKŁADNEGO dopasowania linii, więc wcięcie psuło wyjątki).
if [ -f "$ALLOW" ]; then
  OUT=$(printf '%s\n' "$OUT" | sed 's/^[[:space:]]*//' | grep -vxF -f <(sed 's/^[[:space:]]*//' "$ALLOW" | grep -vE '^\s*#|^\s*$') || true)
fi

if [ -z "${OUT:-}" ]; then
  echo "kernel-wiring: PASS — kerneli spójne w 3 miejscach (crate + manifest + rejestracja)"
  exit 0
fi

echo "kernel-wiring: FAIL — kernel nie jest spójnie podpięty (crate/manifest/rejestracja):"
printf '%s\n' "$OUT" | sed 's/^/  /'
echo "  Reguła: nowy kernel MUSI mieć (1) crate aigon-kernel-<n>, (2) wpis w runtime/manifests/kernels.yaml, (3) mgr.register w aigon-runtime/src/lib.rs."
echo "  Znany dług dopisz do tools/gates/kernel-wiring-allowlist.txt (wolno TYLKO zmniejszać)."
exit 1

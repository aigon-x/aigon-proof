#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/repo-structure.sh — gate repo-structure (cyclic:6h)
#
#  Wykrywa anomalie strukturalne z CANONICAL-STRUCTURE-2026-08-21:
#    R1  config-*.yaml per-noda w runtime/ (configi poza config/)
#    R2  code/ osierocony (duplikat roli products/frontend)
#    R6  nakładanie ról dokumentacyjnych (atlas/ + audit/ + reports/)
#    R8  runtime/credentials/ pusty (katalog bez celu)
#    R9  config.local.yaml vs config-local.yaml DRIFT (oba istnieją)
#    R10 3 ścieżki frontendu (products/frontend + code/frontend + EIC_ACC)
#
#  Exit: 0 = PASS (struktura kanoniczna), 1 = FAIL (anomalie),
#        2 = WARN (brak możliwości sprawdzenia).
#  Ostatnia linia stdout = komunikat (kontrakt hook-runnera).
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

failures=0
found=""

report() {
  found="${found}${1}"$'\n'
  failures=$((failures + 1))
}

# ── R1: config-*.yaml per-noda w runtime/ ─────────────────────────────
# Dozwolone w runtime/: config.yaml, config.test.yaml. Reszta (per-noda,
# config.local.*) = drift — configi mają mieszkać w config/.
per_node=$(find "$ROOT/runtime" -maxdepth 1 -type f \( -name "config-*.yaml" -o -name "config.local.yaml" \) 2>/dev/null | sort)
if [ -n "$per_node" ]; then
  report "R1: configi per-noda w runtime/: $(echo "$per_node" | wc -l) plików ($(echo "$per_node" | tr '\n' ' '))"
fi

# ── ALLOWLIST (2026-10-17): jawne wyjątki z rolą i uzasadnieniem ────────
# Wpis bez `reason` jest IGNOROWANY — allowlist nie może być cichym wyciszeniem.
ALLOW_FILE="${AIGON_REPO_STRUCTURE_ALLOW:-$ROOT/config/canonical/repo-structure-allow.yaml}"
ALLOW_DIRS=""; ALLOW_FRONT=""
if [ -r "$ALLOW_FILE" ]; then
  _parsed="$(python3 - "$ALLOW_FILE" <<'PYEOF'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
def ok(v):
    return isinstance(v, dict) and str(v.get("reason") or "").strip() != ""
print(" ".join(sorted(k for k, v in (d.get("dirs_role_overlap") or {}).items() if ok(v))))
print(" ".join(sorted(k for k, v in (d.get("frontend_paths") or {}).items() if ok(v))))
PYEOF
)"
  ALLOW_DIRS="$(echo "$_parsed" | sed -n 1p)"
  ALLOW_FRONT="$(echo "$_parsed" | sed -n 2p)"
fi

# ── R2: code/ osierocony ──────────────────────────────────────────────
if [ -d "$ROOT/code" ]; then
  report "R2: katalog code/ istnieje (osierocony — duplikat products/frontend)"
fi

# ── R6: nakładanie ról dokumentacyjnych ───────────────────────────────
# atlas/ (1 plik) vs audit/ (raporty) vs reports/ (2389 plików) — role
# rozmyte. Kanon: docs/ konsoliduje atlas+audit, reports/ = wyniki akcji.
for d in atlas audit reports; do
  if [ -d "$ROOT/$d" ]; then
    n=$(find "$ROOT/$d" -type f 2>/dev/null | wc -l)
    if echo " $ALLOW_DIRS " | grep -q " $d "; then
      echo "    WARN R6: $d/ ($n plików) — rola udokumentowana w repo-structure-allow.yaml"
    else
      report "R6: katalog $d/ istnieje ($n plików) — nakładanie ról dokumentacyjnych"
    fi
  fi
done

# ── R8: runtime/credentials/ pusty ────────────────────────────────────
if [ -d "$ROOT/runtime/credentials" ]; then
  n=$(find "$ROOT/runtime/credentials" -type f 2>/dev/null | wc -l)
  if [ "$n" -eq 0 ]; then
    report "R8: runtime/credentials/ pusty (0 plików) — katalog bez celu; sekrety WYŁĄCZNIE config/secrets/"
  fi
fi

# ── R9: config.local.yaml vs config-local.yaml DRIFT ──────────────────
if [ -f "$ROOT/runtime/config.local.yaml" ] && [ -f "$ROOT/runtime/config-local.yaml" ]; then
  report "R9: DRIFT nazewnictwa — oba runtime/config.local.yaml i runtime/config-local.yaml istnieją"
fi

# ── R10: 3 ścieżki frontendu ──────────────────────────────────────────
frontend_paths=()
[ -d "$ROOT/products/frontend" ] && frontend_paths+=("products/frontend")
[ -d "$ROOT/code/frontend" ] && frontend_paths+=("code/frontend")
[ -d "$ROOT/products/akceleratory/EIC_ACC" ] && frontend_paths+=("products/akceleratory/EIC_ACC")
_unallowed=()
for fp in "${frontend_paths[@]}"; do
  if echo " $ALLOW_FRONT " | grep -q " $fp "; then
    echo "    WARN R10: $fp — rola udokumentowana (allowlist)"
  else
    _unallowed+=("$fp")
  fi
done
if [ "${#_unallowed[@]}" -gt 1 ]; then
  report "R10: ${#_unallowed[@]} nieudokumentowane ścieżki frontendu: ${_unallowed[*]}"
fi

# ── Werdykt ───────────────────────────────────────────────────────────
if [ "$failures" -gt 0 ]; then
  echo "FAIL: anomalie strukturalne (${failures}):"
  echo -n "$found" | sed 's/^/  /'
  exit 1
fi

echo "PASS: struktura repo zgodna z kanonem"
exit 0

#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  tools/gates/law-gate-closure.sh — GATE-231 LAW-GATE-CLOSURE
#
#  PO CO (audyt AIOS 2026-10-17, LAW-DEFECT-TO-GATE-1):
#    Prawo bez bramki jest życzeniem. decision-graph raportował 3 prawa
#    „bez realnej bramki", a 30 jako „by design" — bez sprawdzalnej reguły.
#    Ta bramka zamyka KLASĘ: żadne prawo zadeklarowane w config/canonical
#    nie może zostać bez egzekutora, bez jawnego wyjątku z właścicielem
#    i terminem przeglądu, ani wskazywać bramki, która nie istnieje.
#
#  CO MIERZY (struktura, nie proza):
#    C1  Graf decyzyjny istnieje i jest ŚWIEŻY (<= 7 dni) — inaczej STALE.
#    C2  Każde prawo z `law:` w config/canonical/*.yaml ma krawędź
#        law_enforced_by_gate ALBO wpis w law-gate-bindings.yaml ALBO
#        ważny wyjątek w law-gate-exemptions.yaml.
#    C3  Każde wiązanie: target istnieje, a dla external `gate_kind` występuje
#        w runnerze jako gałąź case.
#    C4  Każde wiązanie ACTIVE ma negative_proof (dowód negatywny).
#    C5  Wyjątek bez reason/owner/review_by = FAIL; wyjątek dla prawa, które
#        MA bramkę = FAIL (nieaktualny wyjątek).
#    C6  SUPERSEDED wymaga istniejącego następcy.
#    C7  Bramka wskazana przez prawo musi mieć implementację tools/gates/<id>.sh
#        (dla scope aigon) — inaczej martwy egzekutor.
#
#  KONTRAKT hook-runner: 0 = PASS, 1 = FAIL, 2 = UNKNOWN/BRAK DANYCH (DENY).
#  SELFTEST: --selftest (fixtures; sabotaż ⇒ FAIL, poprawny ⇒ PASS)
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="${AIGON_LAW_CLOSURE_ROOT:-$ROOT_DEFAULT}"
export ROOT

run_check() {
python3 - "$ROOT" <<'PY'
import os, re, sys, glob, datetime
from pathlib import Path

root = Path(sys.argv[1])
canon = root / "config" / "canonical"
graph_p = canon / "decision-graph.yaml"
bind_p = canon / "law-gate-bindings.yaml"
exempt_p = canon / "law-gate-exemptions.yaml"

try:
    import yaml
except ImportError:
    print("UNKNOWN: brak pyyaml")
    sys.exit(2)

def load(p):
    try:
        with open(p, encoding="utf-8") as f:
            return yaml.safe_load(f)
    except Exception as e:
        return None

missing = [str(p) for p in (graph_p, bind_p, exempt_p) if not p.exists()]
if missing:
    print("UNKNOWN: brak wymaganego źródła: " + ", ".join(missing))
    sys.exit(2)

graph = load(graph_p) or {}
bindings = (load(bind_p) or {}).get("bindings") or []
exempt_doc = load(exempt_p) or {}
exemptions = {e.get("id"): e for e in (exempt_doc.get("laws") or []) if isinstance(e, dict)}

fails, warns, notes = [], [], []

# ── C1 świeżość grafu ────────────────────────────────────────────────────
ga = graph.get("generated_at")
if not ga:
    fails.append("C1 graf bez generated_at")
else:
    try:
        ts = datetime.datetime.fromisoformat(str(ga).replace("Z", "+00:00"))
        age_d = (datetime.datetime.now(datetime.timezone.utc) - ts).days
        if age_d > 7:
            fails.append(f"C1 graf STALE: {age_d} dni (limit 7)")
        else:
            notes.append(f"C1 graf świeży: {age_d} dni")
    except Exception:
        fails.append(f"C1 nieczytelny generated_at: {ga!r}")

# ── zbiór praw zadeklarowanych w kanonie ────────────────────────────────
law_decl = {}
for p in sorted(canon.glob("*.yaml")):
    if ".bak" in p.name or p.name in ("decision-graph.yaml",):
        continue
    try:
        txt = p.read_text(encoding="utf-8", errors="replace")
    except Exception:
        continue
    for m in re.finditer(r'^\s*law(?:_id)?:\s*"?([A-Z][A-Z0-9Ω][A-Z0-9Ω._-]*)', txt, re.M):
        lid = m.group(1)
        law_decl.setdefault(lid, str(p.relative_to(root)))

# prawa z konstytucji
cons = load(canon / "constitution.generated.yaml") or {}
for l in (cons.get("laws") or []):
    if l.get("id"):
        law_decl.setdefault(l["id"], "config/canonical/constitution.generated.yaml")

# ── krawędzie law→gate z grafu ──────────────────────────────────────────
law_gates = {}
for e in (graph.get("edges") or []):
    if e.get("rel") == "law_enforced_by_gate" and str(e.get("from", "")).startswith("law:"):
        law_gates.setdefault(e["from"][4:], set()).add(str(e.get("to", "")).replace("gate:", ""))

# ── bindings ────────────────────────────────────────────────────────────
bind_laws = {}
for b in bindings:
    law = b.get("law")
    if not law:
        fails.append("C3 wiązanie bez pola law")
        continue
    bind_laws.setdefault(law, []).append(b)
    target = b.get("target") or ""
    tp = Path(target) if target.startswith("/") else root / target
    if not target or not tp.exists():
        fails.append(f"C3 {law}: target nie istnieje: {target!r}")
        continue
    kind = b.get("gate_kind")
    if kind:
        try:
            body = tp.read_text(encoding="utf-8", errors="replace")
        except Exception:
            body = ""
        if not re.search(r'(^|\n)\s*(?:' + re.escape(str(kind)) + r')\s*\)', body):
            fails.append(f"C3 {law}: gate_kind {kind!r} nie występuje w {target}")
    if b.get("status", "ACTIVE") == "ACTIVE" and not b.get("negative_proof"):
        fails.append(f"C4 {law}: ACTIVE bez negative_proof")
    if b.get("status") == "SUPERSEDED":
        nxt = b.get("superseded_by")
        if not nxt:
            fails.append(f"C6 {law}: SUPERSEDED bez superseded_by")
        elif b.get("scope") == "aigon" and not (root / "tools" / "gates" / f"{nxt}.sh").exists():
            fails.append(f"C6 {law}: następca {nxt} nie istnieje")

# ── C7 egzekutor bramki z grafu ─────────────────────────────────────────
# ── C7: dla bramek o tożsamości GATE-XXX autorytetem jest `command`
# z gate-registry.yaml, NIE nazwa pliku. ZMIERZONE 2026-10-19: GATE-256 ma
# command=tools/gates/sovereign-confirmation.sh, a C7 szukała GATE-256.sh ->
# FAŁSZYWY FAIL blokujący commit całej flocie (bramka mierzyła nie tę rzecz).
_gate_cmd = {}
try:
    _reg = yaml.safe_load((root / "config" / "canonical" / "gate-registry.yaml").read_text())
    for _g in (_reg.get("gates") or []):
        _c = str(_g.get("command") or "").strip().split()
        if _g.get("gate_id") and _c:
            _gate_cmd[str(_g["gate_id"])] = _c[0]
except Exception:
    _gate_cmd = {}

def gate_impl_exists(name: str) -> bool:
    """Bramka może żyć w tools/gates/, tools/gates/fitness/ albo tools/verify/.
    Sprawdzamy PLIK, nie konwencję nazwy — inaczej wzorzec jest za wąski
    (zmierzone 2026-10-17: law-79-fit żyje w tools/gates/fitness/)."""
    _declared = _gate_cmd.get(name)
    if _declared and (root / _declared).exists():
        return True
    for base in (root / "tools" / "gates", root / "tools" / "verify", root / "scripts"):
        for ext in (".sh", ".py"):
            if (base / f"{name}{ext}").exists():
                return True
            if base.exists() and next(base.rglob(f"{name}{ext}"), None):
                return True
    return False

for lid, gs in law_gates.items():
    for g in gs:
        ext = any(b.get("gate") == g and b.get("scope") != "aigon"
                  for b in bind_laws.get(lid, []))
        if not ext and not gate_impl_exists(g):
            fails.append(f"C7 {lid}: bramka {g} bez implementacji (tools/gates|tools/verify)")

# ── C2/C5 domknięcie praw ───────────────────────────────────────────────
unclosed = []
for lid in sorted(law_decl):
    has_graph = bool(law_gates.get(lid))
    has_bind = bool(bind_laws.get(lid))
    ex = exemptions.get(lid)
    if ex:
        # Owner i termin przeglądu mogą być wspólne dla całego rejestru
        # (doc-level default) — jawnie udokumentowana reguła merge.
        owner = ex.get("owner") or exempt_doc.get("owner")
        review = ex.get("review_by") or exempt_doc.get("review_by")
        if not ex.get("reason"):
            fails.append(f"C5 {lid}: wyjątek bez pola reason")
        if not owner:
            fails.append(f"C5 {lid}: wyjątek bez owner (ani wpis, ani rejestr)")
        if not review:
            fails.append(f"C5 {lid}: wyjątek bez review_by (ani wpis, ani rejestr)")
        if has_graph or has_bind:
            fails.append(f"C5 {lid}: nieaktualny wyjątek — prawo MA bramkę")
        continue
    if not has_graph and not has_bind:
        unclosed.append(lid)

if unclosed:
    fails.append("C2 prawa bez bramki i bez wyjątku: " + ", ".join(unclosed))

# ── wynik ───────────────────────────────────────────────────────────────
print(f"prawa zadeklarowane: {len(law_decl)}")
print(f"prawa z krawędzią do bramki: {len(law_gates)}")
print(f"prawa z wiązaniem external: {len(bind_laws)}")
print(f"wyjątki (nie PASS): {len(exemptions)}")
print(f"wiązania: {len(bindings)}")
for n in notes:
    print("NOTE " + n)
for w in warns:
    print("WARN " + w)
if fails:
    for f in fails:
        print("FAIL " + f)
    sys.exit(1)
print("PASS law-gate-closure: każde prawo ma egzekutor albo jawny wyjątek z właścicielem i terminem")
sys.exit(0)
PY
}

selftest() {
  local tmp rc ok=0
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/config/canonical" "$tmp/tools/gates"
  # fixture 1: prawo z bramką w grafie + świeży graf -> PASS
  cat > "$tmp/config/canonical/constitution.generated.yaml" <<'EOF'
laws:
  - id: LAW-A
    name: test
EOF
  cat > "$tmp/config/canonical/law-gate-bindings.yaml" <<'EOF'
version: 1
bindings: []
EOF
  cat > "$tmp/config/canonical/law-gate-exemptions.yaml" <<'EOF'
version: 1
laws: []
EOF
  cat > "$tmp/config/canonical/decision-graph.yaml" <<EOF
generated_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
edges:
  - {from: "law:LAW-A", to: "gate:law-gate-closure", rel: law_enforced_by_gate}
EOF
  cat > "$tmp/config/canonical/x-law.yaml" <<'EOF'
law: LAW-A
EOF
  touch "$tmp/tools/gates/law-gate-closure.sh"
  AIGON_LAW_CLOSURE_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] && echo "selftest 1/4 PASS (poprawne domknięcie)" || { echo "selftest 1/4 FAIL (rc=$rc)"; ok=1; }

  # fixture 2: prawo bez bramki -> FAIL
  cat > "$tmp/config/canonical/y-law.yaml" <<'EOF'
law: LAW-B
EOF
  AIGON_LAW_CLOSURE_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 1 ] && echo "selftest 2/4 PASS (prawo bez bramki złapane)" || { echo "selftest 2/4 FAIL (rc=$rc)"; ok=1; }

  # fixture 3: wyjątek bez reason -> FAIL
  cat > "$tmp/config/canonical/law-gate-exemptions.yaml" <<'EOF'
version: 1
laws:
  - id: LAW-B
    owner: platform
EOF
  AIGON_LAW_CLOSURE_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 1 ] && echo "selftest 3/4 PASS (wyjątek bez reason złapany)" || { echo "selftest 3/4 FAIL (rc=$rc)"; ok=1; }

  # fixture 4: wyjątek dla prawa, które MA bramkę -> FAIL (anti-ratchet)
  cat > "$tmp/config/canonical/law-gate-exemptions.yaml" <<'EOF'
version: 1
laws:
  - id: LAW-A
    reason: "stary wyjątek"
    owner: platform
    review_by: "2026-12-01"
EOF
  AIGON_LAW_CLOSURE_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 1 ] && echo "selftest 4/4 PASS (nieaktualny wyjątek złapany)" || { echo "selftest 4/4 FAIL (rc=$rc)"; ok=1; }

  return "$ok"
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  --json) run_check; exit $? ;;
  "") run_check; exit $? ;;
  *) echo "użycie: $0 [--selftest|--json]" >&2; exit 2 ;;
esac

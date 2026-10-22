#!/usr/bin/env bash
# ============================================================================
# GATE-334 akceleratory-flows — SSOT PRZEPŁYWÓW PRODUKTU AKCELERATORY
# ============================================================================
# PO CO: `products/akceleratory/config/flows.yaml` deklaruje przepływy produktu
# (skan źródeł, crony, usługi). Deklaracja bez ŹRÓDŁA, SKRYPTU, HARMONOGRAMU
# albo CELU to sierota: nikt tego nie uruchomi, a raport będzie wyglądał na
# kompletny. Ten gate mierzy STRUKTURĘ SSOT i ŚWIEŻOŚĆ dowodu przebiegu,
# a nie „czy plik istnieje”.
#
# CO MIERZY (dowód, nie deklaracja):
#   1. SSOT istnieje i PARSuje się; `flows:` niepuste (pusty mianownik != 100%).
#   2. Każdy ENABLED flow ma `target` ORAZ ŹRÓDŁO wymagane przez swój `kind`:
#        scrape  -> `source`      (skąd dane; inaczej nie ma czego pobierać)
#        cron    -> `cron_hint`   (co go uruchamia; inaczej nikt go nie woła)
#        service -> (target = URL sondy JEST obiektem — źródła nie duplikujemy)
#        db      -> (target = tabela JEST obiektem — źródła nie duplikujemy)
#        inny    -> co najmniej jedno z source|script|cron_hint
#      Brak wymaganego pola = SIEROTA = FAIL.
#   3. `id` wymagane i unikalne (duplikat = dwie prawdy o jednym przepływie).
#   4. `script` wskazuje plik, który ISTNIEJE (najpierw względem katalogu
#      produktu, potem względem /opt/PROD — skrypty hostowe żyją w scripts/).
#      Brak pliku = WARN (widoczne; nie blokuje, ale cisza byłaby fałszywym zielonym).
#   5. Dowód przebiegu (`defaults.evidence`, domyślnie data/reports/flow-audit.json):
#      * brak pliku            → STALE/UNKNOWN (WARN) — brak pomiaru != PASS,
#      * wiek > min(max_age_h) → STALE (WARN),
#      * stan FAIL/ERROR/DOWN  → FAIL (przepływ realnie nie działa),
#      * LIMITED bez known_limited → WARN,
#      * przepływ z SSOT bez wpisu w dowodzie (i odwrotnie) → WARN.
#   6. Graf zdrowia (config/canonical/runtime-health-graph.yaml) deklaruje
#      `product:akceleratory` z klasą REAL_PROBE oraz 5 usług produktu
#      (frontend/signal/grants/postgres/redis), każda z sondą i progami.
#      Brak deklaracji = FAIL (pokrycie zdrowia nie może zniknąć po cichu).
#
# KONTRAKT hook-runnera: exit 0 = PASS, exit 2 = WARN/STALE, exit 1 = FAIL.
#
# Użycie:
#   tools/gates/akceleratory-flows.sh              # werdykt
#   tools/gates/akceleratory-flows.sh --json       # wynik maszynowy
#   tools/gates/akceleratory-flows.sh --strict     # STALE/WARN => FAIL
#   tools/gates/akceleratory-flows.sh --selftest   # dowód negatywny (5 przypadków)
# ============================================================================
set -uo pipefail

ROOT="${AIGON_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
ACC_ROOT="${AIGON_ACC_ROOT:-$ROOT/products/akceleratory}"
FLOWS_FILE="${ACC_FLOWS_FILE:-$ACC_ROOT/config/flows.yaml}"
AUDIT_FILE="${ACC_FLOW_AUDIT:-}"     # puste => defaults.evidence z flows.yaml
GRAPH_FILE="${ACC_HEALTH_GRAPH:-$ROOT/config/canonical/runtime-health-graph.yaml}"

STRICT=0
AS_JSON=0
SELFTEST=0
for a in "$@"; do
  case "$a" in
    --strict)   STRICT=1 ;;
    --json)     AS_JSON=1 ;;
    --selftest) SELFTEST=1 ;;
    -h|--help)  sed -n '2,45p' "$0"; exit 0 ;;
    *) printf 'FAIL akceleratory-flows (nieznany argument: %s)\n' "$a"; exit 1 ;;
  esac
done

command -v python3 >/dev/null 2>&1 || { echo "FAIL akceleratory-flows (brak python3)"; exit 1; }

run_check() {
  ROOT="$ROOT" ACC_ROOT="$ACC_ROOT" FLOWS_FILE="$FLOWS_FILE" AUDIT_FILE="$AUDIT_FILE" \
  GRAPH_FILE="$GRAPH_FILE" STRICT="$STRICT" AS_JSON="$AS_JSON" python3 - <<'PYEOF'
import json, os, sys
from datetime import datetime, timezone
from pathlib import Path

try:
    import yaml
except Exception as exc:  # fail-closed: bez parsera nie ma pomiaru
    print(f"FAIL akceleratory-flows (brak pyyaml: {exc})")
    sys.exit(1)

ROOT = Path(os.environ["ROOT"])
ACC = Path(os.environ["ACC_ROOT"])
FLOWS = Path(os.environ["FLOWS_FILE"])
AUDIT_ENV = os.environ.get("AUDIT_FILE", "").strip()
GRAPH = Path(os.environ["GRAPH_FILE"])
STRICT = os.environ.get("STRICT") == "1"
AS_JSON = os.environ.get("AS_JSON") == "1"

REQUIRED_SERVICES = ["frontend", "signal", "grants", "postgres", "redis"]
FAIL_STATES = {"FAIL", "ERROR", "DOWN", "CRITICAL"}
SOFT_STATES = {"PASS", "LIMITED", "WARN", "EXEMPT", "SKIP"}

checks = []   # (level, code, message)
failed = 0
warned = 0


def add(level, code, msg):
    global failed, warned
    checks.append({"level": level, "code": code, "message": msg})
    if level == "FAIL":
        failed += 1
    elif level in ("WARN", "STALE"):
        warned += 1


def rel(p):
    try:
        return str(Path(p).relative_to(ROOT))
    except Exception:
        return str(p)


def is_enabled(flow):
    v = flow.get("enabled", True)
    if isinstance(v, str):
        return v.strip().lower() in ("true", "yes", "1", "on")
    return bool(v)


def text(v):
    return str(v).strip() if v is not None else ""


# ── 1. SSOT przepływów ────────────────────────────────────────────────────
doc = {}
if not FLOWS.is_file():
    add("FAIL", "ssot-missing", f"brak SSOT przepływów: {rel(FLOWS)}")
else:
    try:
        doc = yaml.safe_load(FLOWS.read_text(encoding="utf-8")) or {}
        if not isinstance(doc, dict):
            raise ValueError("korzeń nie jest mapą")
    except Exception as exc:
        add("FAIL", "ssot-parse", f"{rel(FLOWS)} NIE parsuje: {exc}")
        doc = {}

flows = doc.get("flows") if isinstance(doc, dict) else None
if doc and not isinstance(flows, list):
    add("FAIL", "ssot-flows", f"{rel(FLOWS)}: brak listy `flows`")
    flows = []
elif isinstance(flows, list) and not flows:
    add("FAIL", "ssot-empty", f"{rel(FLOWS)}: `flows` puste — pusty mianownik to nie 100%")
    flows = []

enabled = []
for idx, flow in enumerate(flows or []):
    if not isinstance(flow, dict):
        add("FAIL", "flow-shape", f"flows[{idx}] nie jest mapą")
        continue
    fid = text(flow.get("id"))
    if not fid:
        add("FAIL", "flow-id", f"flows[{idx}] bez `id`")
        continue
    if is_enabled(flow):
        enabled.append(flow)

# unikalność id (także wśród wyłączonych — dwie prawdy o jednym id)
seen = {}
for flow in flows or []:
    if not isinstance(flow, dict):
        continue
    fid = text(flow.get("id"))
    if not fid:
        continue
    seen[fid] = seen.get(fid, 0) + 1
for fid, n in sorted(seen.items()):
    if n > 1:
        add("FAIL", "flow-duplicate", f"id `{fid}` wystąpuje {n}× — jedna prawda na przepływ")

enabled_ids = [text(f.get("id")) for f in enabled]

# ── 2/3/4. struktura enabled + istnienie skryptu ──────────────────────────
# Wymagane źródło ZALEŻY od rodzaju przepływu. Dla `service`/`db` obiektem
# sondy jest `target` — żądanie dodatkowego `source` byłoby duplikacją faktu
# i wymuszałoby wpisy-wypełniacze (fałszywa kompletność).
KIND_ORIGIN = {
    "scrape": ("source",),
    "cron": ("cron_hint",),
    "service": (),
    "db": (),
}
script_missing = 0
for flow in enabled:
    fid = text(flow.get("id"))
    kind = text(flow.get("kind")).lower()
    target = text(flow.get("target"))
    origins = {k: text(flow.get(k)) for k in ("source", "script", "cron_hint")}

    if not target:
        add("FAIL", "orphan", f"flow `{fid}`: SIEROTA — brak `target` (dokąd ma trafić?)")

    if kind in KIND_ORIGIN:
        needed = KIND_ORIGIN[kind]
        for field in needed:
            if not origins[field]:
                add("FAIL", "orphan",
                    f"flow `{fid}` (kind={kind}): SIEROTA — brak `{field}`")
    elif not any(origins.values()):
        add("FAIL", "orphan",
            f"flow `{fid}` (kind={kind or '?'}): SIEROTA — brak `source`, `script` i `cron_hint`")

    script = origins["script"]
    if script:
        sp = Path(script)
        if not sp.is_absolute():
            # produkt -> kanoniczny root (skrypty hostowe: /opt/PROD/scripts/*)
            for base in (ACC, ROOT):
                if (base / script).exists():
                    sp = base / script
                    break
            else:
                sp = ACC / script
        if not sp.exists():
            script_missing += 1
            add("WARN", "script-missing",
                f"flow `{fid}`: `script` = {script} nie istnieje (szukano w {rel(ACC)} i {rel(ROOT)})")

if enabled:
    add("PASS", "structure", f"enabled={len(enabled)} — każdy z target i origin"
        if failed == 0 else f"enabled={len(enabled)} — sprawdzono strukturę")
    if not script_missing:
        add("PASS", "scripts", "wszystkie wskazane skrypty istnieją")

# ── 5. dowód przebiegu: świeżość + zgodność stanów ────────────────────────
defaults = doc.get("defaults") if isinstance(doc.get("defaults"), dict) else {}
evidence_rel = AUDIT_ENV or text(defaults.get("evidence")) or "data/reports/flow-audit.json"
evidence = Path(evidence_rel)
if not evidence.is_absolute():
    evidence = ACC / evidence_rel

budgets = []
for flow in enabled:
    try:
        mh = float(flow.get("max_age_h"))
    except (TypeError, ValueError):
        continue
    if mh > 0:
        budgets.append(mh)
    elif flow.get("max_age_h") is not None and mh < 0:
        add("WARN", "flow-max-age", f"flow `{text(flow.get('id'))}`: ujemny `max_age_h`")
budget = min(budgets) if budgets else None

audit = {}
if not evidence.is_file():
    add("STALE", "evidence-missing",
        f"brak dowodu przebiegu {rel(evidence)} — brak pomiaru != PASS (STALE/UNKNOWN)")
else:
    age_h = None
    try:
        audit = json.loads(evidence.read_text(encoding="utf-8")) or {}
    except Exception as exc:
        add("WARN", "evidence-parse", f"{rel(evidence)} NIE parsuje: {exc}")
        audit = {}

    ts_raw = text(audit.get("ts")) if isinstance(audit, dict) else ""
    stamp = None
    if ts_raw:
        for fmt in ("%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%dT%H:%M:%S.%f%z", "%Y-%m-%d %H:%M:%S"):
            try:
                stamp = datetime.strptime(ts_raw, fmt)
                break
            except ValueError:
                continue
    if stamp is None:
        stamp = datetime.fromtimestamp(evidence.stat().st_mtime).astimezone()
    age_h = (datetime.now(timezone.utc) - stamp.astimezone(timezone.utc)).total_seconds() / 3600.0

    if budget is not None:
        if age_h > budget:
            add("STALE", "evidence-stale",
                f"dowód {rel(evidence)} ma {age_h:.1f} h > max_age_h={budget:g} (ts={ts_raw or 'mtime'})")
        else:
            add("PASS", "evidence-fresh",
                f"dowód świeży: {age_h:.1f} h <= max_age_h={budget:g} (ts={ts_raw or 'mtime'})")
    else:
        add("WARN", "evidence-budget", "brak dodatniego max_age_h — nie da się orzec świeżości")

    rows = audit.get("flows") if isinstance(audit, dict) else None
    if isinstance(rows, list):
        by_id = {}
        for row in rows:
            if isinstance(row, dict):
                by_id[text(row.get("id"))] = row
        audit_ids = set(by_id)
        enabled_set = set(enabled_ids)
        flow_by_id = {text(f.get("id")): f for f in enabled}

        for fid in sorted(enabled_set - audit_ids):
            add("WARN", "evidence-gap", f"flow `{fid}` z SSOT nie ma wpisu w dowodzie (brak pomiaru)")
        for fid in sorted(audit_ids - enabled_set):
            add("WARN", "evidence-extra", f"dowód zawiera `{fid}`, którego nie ma w SSOT (stary audyt?)")

        for fid in sorted(enabled_set & audit_ids):
            row = by_id.get(fid) or {}
            state = text(row.get("state")).upper()
            if state in FAIL_STATES:
                add("FAIL", "evidence-fail", f"flow `{fid}`: stan {state} w dowodzie — przepływ nie działa")
            elif state and state not in SOFT_STATES:
                add("WARN", "evidence-state", f"flow `{fid}`: nieznany stan {state}")
            elif state == "LIMITED" and not (flow_by_id.get(fid) or {}).get("known_limited"):
                add("WARN", "evidence-limited",
                    f"flow `{fid}`: LIMITED bez `known_limited` w SSOT (ograniczenie nieudokumentowane)")

        if enabled_set and enabled_set == audit_ids:
            add("PASS", "evidence-coverage", f"dowód pokrywa {len(audit_ids)}/{len(enabled_set)} enabled flow")
    elif audit:
        add("WARN", "evidence-shape", f"{rel(evidence)}: brak listy `flows` — dowód nieczytelny")

# ── 6. deklaracja w grafie zdrowia ────────────────────────────────────────
if not GRAPH.is_file():
    add("WARN", "graph-missing", f"brak grafu zdrowia {rel(GRAPH)} — nie weryfikuję deklaracji produktu")
else:
    try:
        graph = yaml.safe_load(GRAPH.read_text(encoding="utf-8")) or {}
    except Exception as exc:
        add("FAIL", "graph-parse", f"{rel(GRAPH)} NIE parsuje: {exc}")
        graph = {}
    products = graph.get("products") if isinstance(graph, dict) else None
    element = (products or {}).get("product:akceleratory") if isinstance(products, dict) else None
    if not isinstance(element, dict):
        add("FAIL", "graph-product",
            f"{rel(GRAPH)}: brak elementu `products.product:akceleratory` — pokrycie zdrowia produktu nie może zniknąć po cichu")
    else:
        if text(element.get("evidence_class")) != "REAL_PROBE":
            add("FAIL", "graph-class",
                "products.product:akceleratory: evidence_class != REAL_PROBE (deklaracja bez sondy)")
        if not isinstance(element.get("thresholds"), dict) or not element.get("thresholds"):
            add("FAIL", "graph-thresholds", "products.product:akceleratory: brak `thresholds`")

        svc = element.get("services")
        svc_ids = set(svc) if isinstance(svc, dict) else {text(s.get("id")) for s in (svc or []) if isinstance(s, dict)}
        missing_svc = [s for s in REQUIRED_SERVICES if s not in svc_ids]
        if missing_svc:
            add("FAIL", "graph-services",
                "products.product:akceleratory: brak usług w grafie: " + ", ".join(missing_svc))
        for sid in REQUIRED_SERVICES:
            entry = svc.get(sid) if isinstance(svc, dict) else None
            if isinstance(entry, dict):
                if text(entry.get("evidence_class")) != "REAL_PROBE":
                    add("FAIL", "graph-service-class",
                        f"products.product:akceleratory.services.{sid}: evidence_class != REAL_PROBE")
                if not isinstance(entry.get("thresholds"), dict) or not entry.get("thresholds"):
                    add("FAIL", "graph-service-thresholds",
                        f"products.product:akceleratory.services.{sid}: brak `thresholds`")
                if not isinstance(entry.get("probe"), dict) or not entry.get("probe"):
                    add("FAIL", "graph-service-probe",
                        f"products.product:akceleratory.services.{sid}: brak `probe`")
        if not missing_svc:
            add("PASS", "graph", f"graf zdrowia deklaruje product:akceleratory + {len(REQUIRED_SERVICES)} usług REAL_PROBE")

# ── werdykt ───────────────────────────────────────────────────────────────
if failed:
    status, code = "FAIL", 1
elif warned and STRICT:
    status, code = "FAIL", 1
elif warned:
    status, code = "WARN", 2
else:
    status, code = "PASS", 0

if AS_JSON:
    print(json.dumps({
        "gate": "akceleratory-flows",
        "gate_id": "GATE-334",
        "status": status,
        "exit": code,
        "ssot": rel(FLOWS),
        "enabled_flows": len(enabled),
        "evidence": rel(evidence),
        "evidence_budget_h": budget,
        "failed": failed,
        "warned": warned,
        "strict": STRICT,
        "checks": checks,
    }, ensure_ascii=False, indent=2))
    sys.exit(code)

print("akceleratory-flows: SSOT przepływów produktu (GATE-334)")
print(f"  SSOT:     {rel(FLOWS)}")
print(f"  dowód:    {rel(evidence)}")
print(f"  graf:     {rel(GRAPH)}")
for c in checks:
    print(f"  {c['level']:<5} [{c['code']}] {c['message']}")
print("-" * 78)
print(f"FLOWS enabled={len(enabled)}  FAIL={failed}  WARN/STALE={warned}  strict={int(STRICT)}")
print(f"VERDICT: {status} (exit {code})")
sys.exit(code)
PYEOF
}

# ── dowód negatywny: bramka MUSI paść, gdy SSOT ma sierotę ────────────────
selftest() {
  local tmp rc=0 out
  tmp="$(mktemp -d /tmp/acc-flows-selftest.XXXXXX)"
  trap 'rm -rf "$tmp"' RETURN

  mkdir -p "$tmp/acc/config" "$tmp/acc/data/reports" "$tmp/acc/tools" "$tmp/canon"
  : > "$tmp/acc/tools/ok.sh"

  graph_ok="$tmp/canon/graph.yaml"
  cat > "$graph_ok" <<'YAML'
schema_version: 1
products:
  product:akceleratory:
    product: akceleratory
    evidence_class: REAL_PROBE
    probe: {kind: structure, script: tools/gates/akceleratory-flows.sh}
    thresholds: {pass_ratio: 1.0, max_stale_age_h: 2}
    services:
      frontend: {evidence_class: REAL_PROBE, probe: {type: http}, thresholds: {latency_warn_ms: 1500}}
      signal:   {evidence_class: REAL_PROBE, probe: {type: http}, thresholds: {latency_warn_ms: 1500}}
      grants:   {evidence_class: REAL_PROBE, probe: {type: http}, thresholds: {latency_warn_ms: 1500}}
      postgres: {evidence_class: REAL_PROBE, probe: {type: tcp},  thresholds: {connect_warn_ms: 200}}
      redis:    {evidence_class: REAL_PROBE, probe: {type: redis_ping}, thresholds: {connect_warn_ms: 200}}
YAML

  # wspólny, świeży dowód
  python3 - "$tmp/acc/data/reports/flow-audit.json" <<'PY'
import json, sys
from datetime import datetime
json.dump({"ts": datetime.now().astimezone().strftime("%Y-%m-%dT%H:%M:%S%z"),
           "flows": [{"id": i, "state": "PASS"} for i in ("a", "b", "svc", "db")]},
          open(sys.argv[1], "w"))
PY

  check() { # <nazwa> <oczekiwany_exit> <flows_file> <graph_file> [env age]
    local name="$1" want="$2" flows="$3" graph="$4" age="${5:-}"
    local extra=()
    [ -n "$age" ] && extra=(env ACC_FLOW_AUDIT_TS="$age")
    out="$(ROOT="$tmp" AIGON_ACC_ROOT="$tmp/acc" ACC_FLOWS_FILE="$flows" \
           ACC_HEALTH_GRAPH="$graph" bash "$0" 2>&1)"; rc=$?
    if [ "$rc" -eq "$want" ]; then
      printf 'SELFTEST PASS  %-34s exit=%s (oczekiwany %s)\n' "$name" "$rc" "$want"
    else
      printf 'SELFTEST FAIL  %-34s exit=%s (oczekiwany %s)\n%s\n' "$name" "$rc" "$want" "$out"
      SELFTEST_RC=1
    fi
  }
  SELFTEST_RC=0

  # 1. zdrowy — w tym flow `service` i `db`, które NIE wymagają `source`
  #    (dla nich target JEST obiektem sondy; dowód, że reguła nie jest za szeroka).
  cat > "$tmp/healthy.yaml" <<'YAML'
schema: 1
defaults: {evidence: data/reports/flow-audit.json}
flows:
- {id: a, kind: scrape, source: s1, target: grants.signal_events, max_age_h: 2, enabled: true}
- {id: b, kind: cron, cron_hint: b, script: tools/ok.sh, target: file.prom, max_age_h: 2, enabled: true}
- {id: svc, kind: service, target: "http://127.0.0.1:4100/", max_age_h: 0, enabled: true}
- {id: db, kind: db, target: grants.grants, max_age_h: 0, enabled: true}
YAML
  check "healthy" 0 "$tmp/healthy.yaml" "$graph_ok"

  # 2. sierota (target bez origin)
  cat > "$tmp/orphan.yaml" <<'YAML'
schema: 1
defaults: {evidence: data/reports/flow-audit.json}
flows:
- {id: a, kind: scrape, source: s1, target: grants.signal_events, max_age_h: 2, enabled: true}
- {id: orphan, kind: scrape, target: grants.signal_events, max_age_h: 2, enabled: true}
YAML
  check "orphan" 1 "$tmp/orphan.yaml" "$graph_ok"

  # 3. duplikat id
  cat > "$tmp/dup.yaml" <<'YAML'
schema: 1
defaults: {evidence: data/reports/flow-audit.json}
flows:
- {id: a, kind: scrape, source: s1, target: t, max_age_h: 2, enabled: true}
- {id: a, kind: cron, cron_hint: a, target: t, max_age_h: 2, enabled: true}
YAML
  check "duplicate-id" 1 "$tmp/dup.yaml" "$graph_ok"

  # 4. STALE (dowód starszy niż max_age_h)
  mkdir -p "$tmp/stale"
  cat > "$tmp/stale/flows.yaml" <<'YAML'
schema: 1
defaults: {evidence: audit.json}
flows:
- {id: a, kind: scrape, source: s1, target: t, max_age_h: 2, enabled: true}
YAML
  python3 - "$tmp/stale/audit.json" <<'PY'
import json, sys
from datetime import datetime, timedelta
ts = (datetime.now().astimezone() - timedelta(hours=10)).strftime("%Y-%m-%dT%H:%M:%S%z")
json.dump({"ts": ts, "flows": [{"id": "a", "state": "PASS"}]}, open(sys.argv[1], "w"))
PY
  out="$(ROOT="$tmp" AIGON_ACC_ROOT="$tmp/stale" ACC_FLOWS_FILE="$tmp/stale/flows.yaml" \
         ACC_HEALTH_GRAPH="$graph_ok" bash "$0" 2>&1)"; rc=$?
  if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'evidence-stale'; then
    printf 'SELFTEST PASS  %-34s exit=%s (oczekiwany 2, STALE)\n' "stale-evidence" "$rc"
  else
    printf 'SELFTEST FAIL  %-34s exit=%s (oczekiwany 2)\n%s\n' "stale-evidence" "$rc" "$out"
    SELFTEST_RC=1
  fi

  # 5. graf bez deklaracji produktu
  printf 'schema_version: 1\nproducts: {}\n' > "$tmp/canon/graph-empty.yaml"
  check "graph-without-product" 1 "$tmp/healthy.yaml" "$tmp/canon/graph-empty.yaml"

  echo "-" && echo "SELFTEST: $([ "$SELFTEST_RC" -eq 0 ] && echo PASS || echo FAIL) (5 przypadków)"
  return "$SELFTEST_RC"
}

if [ "$SELFTEST" -eq 1 ]; then
  selftest
  exit $?
fi

run_check

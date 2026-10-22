#!/usr/bin/env bash
# no-duplicate-scrape.sh — LAW-NO-DUPLICATE-SCRAPE-1.
# PASS gdy każdy adres:port metryk występuje w DOKŁADNIE JEDNYM jobie.
# Sprawdza: static_configs.targets + file_sd (pliki targetów, jeśli istnieją).
# --selftest: dowód pozytywny (brak duplikatu => PASS) i negatywny (duplikat => FAIL).
set -uo pipefail
ROOT="${AIGON_ROOT:-/srv/aigon}"
PROM="${PROM_YML:-$ROOT/observability/prometheus/prometheus.yml}"

check() {
  python3 - "$1" <<'PY'
import re, sys, os, glob, json
p = sys.argv[1]
try:
    import yaml
except ImportError:
    print("FAIL: brak PyYAML"); sys.exit(2)
try:
    d = yaml.safe_load(open(p))
except Exception as e:
    print("FAIL: nie parsuje %s: %s" % (p, e)); sys.exit(2)
jobs = (d or {}).get("scrape_configs") or []
seen = {}
for j in jobs:
    name = j.get("job_name", "?")
    addrs = []
    for key in ("static_configs",):
        for sc in (j.get(key) or []):
            addrs += [str(x) for x in (sc.get("targets") or [])]
    for fsd in (j.get("file_sd_configs") or []):
        for pat in (fsd.get("files") or []):
            for f in glob.glob(pat.replace("/etc/prometheus", os.path.join(os.environ.get("PROM_DIR", "/srv/aigon/observability/prometheus")))):
                try:
                    data = json.load(open(f))
                except Exception:
                    continue
                for t in data:
                    addrs += [str(x) for x in (t.get("targets") or [])]
    for a in addrs:
        seen.setdefault(a, []).append(name)
# WYJATEK KANONICZNY (2026-10-22): `mesh-tls-*` to SONDY TLS, nie producent
# metryk. Para mesh-tls-* + job funkcjonalny = celowe użycie portu (probe+scrape).
def _is_tls_probe(jobs):
    return any(str(j).startswith("mesh-tls-") for j in jobs)
dups, tls_pairs = {}, {}
for a, j in seen.items():
    if len(j) <= 1:
        continue
    if _is_tls_probe(j):
        tls_pairs[a] = j
    else:
        dups[a] = j
for a, j in sorted(tls_pairs.items()):
    print("INFO: TLS-probe + scrape (dozwolone): %s -> %s" % (a, ", ".join(j)))
if dups:
    print("FAIL: duplikat scrape (adres -> joby):")
    for a, j in sorted(dups.items()):
        print("  %s -> %s" % (a, ", ".join(j)))
    sys.exit(1)
print("PASS: %d adresów, każdy w dokładnie jednym jobie" % len(seen))
sys.exit(0)
PY
}

if [ "${1:-}" = "--selftest" ]; then
  tmpd=$(mktemp -d); trap 'rm -rf "$tmpd"' EXIT
  ok=0; fail=0
  cat > "$tmpd/good.yml" <<'YAML'
scrape_configs:
  - job_name: a
    static_configs: [{targets: ["127.0.0.1:9188"]}]
  - job_name: b
    static_configs: [{targets: ["127.0.0.1:3001"]}]
YAML
  cat > "$tmpd/bad.yml" <<'YAML'
scrape_configs:
  - job_name: a
    static_configs: [{targets: ["127.0.0.1:9188"]}]
  - job_name: b
    static_configs: [{targets: ["127.0.0.1:9188"]}]
YAML
  check "$tmpd/good.yml" >/dev/null && ok=1
  check "$tmpd/bad.yml"  >/dev/null || fail=1
  if [ "$ok" = 1 ] && [ "$fail" = 1 ]; then echo "SELFTEST PASS"; exit 0; fi
  echo "SELFTEST FAIL (positive=$ok negative=$fail)"; exit 1
fi

check "$PROM"

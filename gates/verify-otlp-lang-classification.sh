#!/usr/bin/env bash
# verify-otlp-lang-classification.sh — dowód, że bramka OTLP-CA klasyfikuje
# JĘZYK Z RUNTIME, a nie z nazwy obrazu.
#
# PO CO: przed poprawką 2026-09-29 `expected_env()` zgadywał język po nazwie
# obrazu i polu USER. Oba kłamią:
#   monai:0.2.0       → Python 3.12, nazwa nie zawiera "python"
#   monai-api:1.2.0   → Node 18,     nazwa nie zawiera "node"
#   grantmaster-app-* → Python 3.11, ale pole USER/konwencja wskazywała Node
# Skutek: bramka wymagała zmiennej w formacie NIEWŁAŚCIWEGO języka
# (np. AIGON_TLS_CA_CERT od Pythona, NODE_EXTRA_CA_CERTS od Pythona), więc
# albo dawała fałszywy FAIL, albo — gorzej — fałszywy PASS, gdy kontener
# przypadkiem miał zmienną właściwą dla zgadniętego języka.
#
# Ten skrypt porównuje klasyfikację STARĄ z NOWĄ na żywych kontenerach.
# Kontrakt: każdy kontener, gdzie interpreter DA SIĘ zmierzyć, MUSI dać
# klasyfikację zgodną z interpreterem. Rozbieżność = FAIL.
set -uo pipefail
P=0; F=0
ok(){ echo "  PASS: $1"; P=$((P+1)); }
bad(){ echo "  FAIL: $1"; F=$((F+1)); }

echo "=== A. INTERPRETER Z RUNTIME (twardy pomiar) ==="
python3 - <<'PY'
import re, subprocess, sys

def sh(*a):
    return subprocess.run(a, capture_output=True, text=True).stdout

# STARA logika — kopia oryginału (nazwa obrazu + USER).
def old_lang(image, user=""):
    i, u = image.lower(), (user or "").lower()
    if "python" in i: return "python"
    if u.startswith("node") or "node" in i or "next" in i or "grantmaster" in i: return "node"
    if "haproxy" in i: return "haproxy"
    if u.startswith("appuser"): return "node"
    return "rust"

# NOWA logika — interpreter z żywego kontenera.
def rt_lang(c):
    for probe, lang in ((("python3", "--version"), "python"),
                        (("python", "--version"), "python"),
                        (("node", "--version"), "node"),
                        (("go", "version"), "go")):
        o = sh("docker", "exec", c, *probe)
        if "Python" in o: return "python"
        if "go version" in o: return "go"
        if lang == "node" and re.match(r"^v\d", o.strip()): return "node"
    return ""

names = sh("docker", "ps", "--format", "{{.Names}}").split()
rows, worse, better = [], 0, 0
for c in names:
    env = sh("docker", "inspect", c, "--format", "{{range .Config.Env}}{{println .}}{{end}}")
    ep = ""
    for l in env.splitlines():
        if l.startswith(("AIGON_OTLP_ENDPOINT=", "OTEL_EXPORTER_OTLP_ENDPOINT=")):
            ep = l.split("=", 1)[1]; break
    if "44318" not in ep:
        continue
    img = sh("docker", "inspect", c, "--format", "{{.Config.Image}}").strip()
    usr = sh("docker", "inspect", c, "--format", "{{.Config.User}}").strip()
    o, n = old_lang(img, usr), rt_lang(c)
    rows.append((c, o, n or o))
    if n and o != n:
        better += 1

print("%-26s %-10s %-10s %s" % ("kontener", "STARA", "NOWA", "ZMIANA"))
for c, o, n in sorted(rows):
    print("%-26s %-10s %-10s %s" % (c, o, n, "TAK" if o != n else "-"))
print()
print("klientow OTLP: %d | przeklasyfikowanych: %d" % (len(rows), better))
# Dowod naprawy: co najmniej jeden kontener zmienil klasyfikacje.
sys.exit(0 if better > 0 else 1)
PY
[ $? -eq 0 ] && ok "klasyfikacja z runtime rozni sie od starej (naprawa dziala)" \
             || bad "brak zmian klasyfikacji — naprawa nie dziala"

echo "=== B. SKLADNIA bramki ==="
G=/opt/PROD/tools/gates/otlp-client-ca-check.sh
bash -n "$G" 2>/dev/null && ok "bash -n" || bad "bash -n"

echo "=== C. BRAMKA UZYWA runtime, NIE nazwy ==="
if grep -q "detect_lang_from_runtime" "$G" && grep -q "container=c" "$G"; then
  ok "detect_lang_from_runtime istnieje i jest wolane z 'container='"
else
  bad "bramka nie wola detekcji z runtime"
fi

echo
echo "=================================================="
echo "WYNIK: $P PASS / $F FAIL"
echo "=================================================="
exit "$F"

#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  tools/gates/binary-glibc-fit.sh — GATE: binarka z bind-mountu MUSI dzialac
#  na glibc kontenera docelowego (hook-runner: tools/gates/<id>.sh).
#
#  PO CO (incydent 2026-09-22, zmierzony): do kanonicznej lokalizacji
#  /opt/PROD/runtime-bin/localbin/aigon-code-server wstawiono obca binarke
#  zebudowana na glibc 2.39 (15 MB, rozmiar identyczny z runtime/target/release),
#  a obraz 127.0.0.1:55000/aigon-code-server:production ma glibc 2.36 (Debian 12).
#  Skutek: `/usr/local/bin/aigon-code-server: libc.so.6: version GLIBC_2.39 not
#  found` -> bramka agentow :38080 NIE WSTAWALA (petla restartow), zniknely
#  narzedzia MCP, a ratchet stanu zglosil `local_ports_up 15 -> 13` i zablokowal
#  push. Defekt byl CICHY: obraz sie buduje, kontener sie tworzy, log ma jedna
#  linie, ktorej nikt nie czyta.
#
#  CO ROBI: dla kazdego montazu `.../runtime-bin/localbin/<bin>:<sciezka>` w
#  docker-compose.yml liczy NAJWYZSZA wymagana wersje GLIBC binarki (strings) i
#  porownuje z glibc OBRAZU uslugi (ldd w kontenerze jednorazowym). Binarka
#  wymagajaca wiecej niz obraz = FAIL (blokujacy) z dokladnymi wersjami.
#
#  Kontrakt hook-runner: exit 0 = PASS/WARN, exit 1 = FAIL.
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

python3 - <<'PY'
import re, subprocess, sys, os

ROOT = os.getcwd()
compose = os.path.join(ROOT, "docker-compose.yml")
if not os.path.isfile(compose):
    print("WARN binary-glibc-fit (brak docker-compose.yml)")
    sys.exit(0)

text = open(compose, encoding="utf-8", errors="replace").read()

# usluga -> obraz
svc_img = {}
cur = None
for line in text.splitlines():
    m = re.match(r'^  ([a-zA-Z0-9_.-]+):\s*$', line)
    if m:
        cur = m.group(1)
        continue
    m = re.match(r'^    image:\s*(\S+)', line)
    if m and cur:
        svc_img[cur] = m.group(1)

def num(v):
    return tuple(int(x) for x in v.split("."))

def glibc_of_binary(path):
    try:
        out = subprocess.run(["strings", path], capture_output=True, text=True, timeout=120).stdout
    except Exception:
        return None
    vers = re.findall(r'GLIBC_(\d+\.\d+)', out)
    if not vers:
        return None
    return max(vers, key=num)

def glibc_of_image(image):
    try:
        r = subprocess.run(["docker", "run", "--rm", "--entrypoint", "sh", image,
                            "-c", "ldd --version 2>/dev/null | head -1"],
                           capture_output=True, text=True, timeout=180)
        m = re.search(r'GLIBC\s+(\d+\.\d+)', r.stdout) or re.search(r'(\d+\.\d+)\s*$', r.stdout.strip())
        return m.group(1) if m else None
    except Exception:
        return None

# mounty z runtime-bin/localbin
mounts = re.findall(r'^\s*-\s*(/opt/PROD/runtime-bin/localbin/[A-Za-z0-9._-]+):(\S+?)(?::ro)?\s*$',
                    text, re.M)
if not mounts:
    print("WARN binary-glibc-fit (zero montazy runtime-bin/localbin w compose)")
    sys.exit(0)

# ktora usluga montuje dany plik
svc_of = {}
cur = None
for line in text.splitlines():
    m = re.match(r'^  ([a-zA-Z0-9_.-]+):\s*$', line)
    if m:
        cur = m.group(1)
        continue
    m = re.match(r'^\s*-\s*(/opt/PROD/runtime-bin/localbin/[A-Za-z0-9._-]+):', line)
    if m and cur:
        svc_of.setdefault(m.group(1), cur)

cache, fails, checked = {}, [], 0
for host, cpath in mounts:
    if not os.path.isfile(host):
        print("  WARN brak pliku: %s" % host)
        continue
    svc = svc_of.get(host)
    img = svc_img.get(svc)
    if not img:
        print("  WARN nie znam obrazu dla %s (usluga %s)" % (host, svc))
        continue
    if img not in cache:
        cache[img] = glibc_of_image(img)
    need = glibc_of_binary(host)
    have = cache[img]
    checked += 1
    if need is None or have is None:
        print("  WARN nie ustalilem wersji: %s (binaria=%s obraz=%s)" % (host, need, have))
        continue
    rel = os.path.relpath(host, ROOT)
    if num(need) > num(have):
        fails.append((rel, svc, need, have))
        print("  FAIL %s: wymaga GLIBC_%s, obraz %s ma %s" % (rel, need, svc, have))
    else:
        print("  PASS %s: wymaga GLIBC_%s <= obraz %s (%s)" % (rel, need, svc, have))

if fails:
    print("FAIL binary-glibc-fit: %d/%d binarek nie uruchomi sie na glibc obrazu" % (len(fails), checked))
    sys.exit(1)
print("PASS binary-glibc-fit: %d/%d binarek zgodnych z glibc obrazow" % (checked, checked))
PY

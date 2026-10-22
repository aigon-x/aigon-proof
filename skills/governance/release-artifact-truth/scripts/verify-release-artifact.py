#!/usr/bin/env python3
"""Sonda ad-hoc tozsamosci artefaktu wydania (NIE suite green).

Sprawdza jedno wydanie w czterech miejscach:
  manifest (release.json)  ->  config publikujacy (yaml)  ->  dysk (sha256+rozmiar)
  ->  publiczny URL (bajty)  ->  wyrenderowany dist (opcjonalnie)

Uzycie:
  python3 verify-release-artifact.py \
      --manifest /opt/projects/inorg/pluskwa/app/release.json \
      --yaml /opt/projects/inorg/landingfull/srv/src/data/produkty.yaml \
      --slug pluskwa \
      --dist /opt/projects/inorg/landingfull/srv/dist/produkty/index.html \
      --dist /opt/projects/inorg/landingfull/srv/dist/produkty/pluskwa/index.html

Kod wyjscia: 0 = wszystkie asercje PASS, 1 = rozjazd (wypisuje ktore).
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys

import yaml

fails = []


def check(name, cond, detail):
    print(("  PASS  " if cond else "  FAIL  ") + name + " :: " + detail)
    if not cond:
        fails.append(name)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def load_entries(path):
    data = yaml.safe_load(open(path, encoding="utf-8"))
    if isinstance(data, dict):
        for key in ("produkty", "products", "items"):
            if key in data:
                return data[key]
        raise SystemExit("yaml: brak listy produktow (produkty/products/items)")
    return data


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True, help="release.json (SSOT wydania)")
    ap.add_argument("--yaml", required=True, help="config publikujacy (produkty.yaml)")
    ap.add_argument("--slug", required=True)
    ap.add_argument("--manifest-dir", default=None, help="katalog z artefaktem (domyslnie: katalog manifestu)")
    ap.add_argument("--dist", action="append", default=[], help="wyrenderowany HTML do kontroli href (mozna wielokrotnie)")
    ap.add_argument("--no-http", action="store_true", help="pomin probe sieciowa")
    args = ap.parse_args()

    man = json.load(open(args.manifest, encoding="utf-8"))
    ver = str(man["versionName"])
    apk_name = man["apk"]
    man_sha = man["sha256"].lower()
    art_dir = args.manifest_dir or os.path.dirname(args.manifest)
    art_path = os.path.join(art_dir, apk_name)

    entry = next((e for e in load_entries(args.yaml) if e.get("slug") == args.slug), None)
    if entry is None:
        raise SystemExit(f"yaml: brak wpisu slug={args.slug}")
    linki = entry.get("linki") or {}
    url = linki.get("apk", "")
    yaml_ver = str(linki.get("apk_wersja", ""))
    yaml_mb = float(linki.get("apk_rozmiar_mb") or 0)
    dowod = " ".join(entry.get("status_dowod") or [])

    print("[1] manifest vs config vs dysk")
    check("wersja = manifest", yaml_ver == ver, f"{yaml_ver} vs {ver}")
    check("nazwa pliku = manifest", url.rsplit("/", 1)[-1] == apk_name, f"{url.rsplit('/', 1)[-1]} vs {apk_name}")
    check("sha256 w URL = manifest", man_sha[:16] in url, f"prefix {man_sha[:16]} w {url}")
    if os.path.isfile(art_path):
        size = os.stat(art_path).st_size
        check("sha256 dysk = manifest", sha256_file(art_path) == man_sha, art_path)
        check("rozmiar MB = round(B/MiB,2)", abs(yaml_mb - round(size / 1048576, 2)) < 0.005,
              f"yaml {yaml_mb} = {size} B -> {round(size / 1048576, 2)}")
    else:
        size = None
        check("artefakt na dysku", False, f"brak {art_path}")

    print("[2] wpis dowodowy nie klamie wersji")
    check("dowod zawiera biezaca wersje", f"APK {ver}:" in dowod, f"szukano 'APK {ver}:'")
    obce = [m for m in re.findall(r"APK (\d+\.\d+\.\d+):", dowod) if m != ver]
    check("brak obcej wersji w dowodzie", not obce, f"obce: {sorted(set(obce))}")

    if not args.no_http:
        print("[3] publiczny URL — dowod z bajtow")
        out = subprocess.run(
            ["curl", "-fsS", "-o", os.devnull, "-w", "%{http_code} %{content_type} %{size_download}",
             "-H", "Cache-Control: no-cache", url],
            capture_output=True, text=True)
        if out.returncode != 0:
            check("HTTP pobranie", False, f"curl -f exit {out.returncode}: {out.stderr.strip()[:120]}")
        else:
            code, ctype, got = out.stdout.split()
            check("HTTP 200", code == "200", url)
            if apk_name.endswith(".apk"):
                check("content-type APK", ctype == "application/vnd.android.package-archive", ctype)
            else:
                check("content-type nie HTML", "text/html" not in ctype, ctype)
            if size is not None:
                check("size_download = rozmiar z dysku", int(got) == size, f"{got} vs {size}")

    print("[4] wyrenderowany dist — to, co widzi uzytkownik")
    pattern = re.compile(re.escape(args.slug) + r"-\d+\.\d+\.\d+-[0-9a-f]{8,}\.apk")
    for path in args.dist:
        html = open(path, encoding="utf-8").read()
        tag = path.rsplit("/dist/", 1)[-1]
        check(f"{tag}: href biezacego wydania", url in html, "obecny" if url in html else "BRAK")
        obce_apk = sorted({m for m in pattern.findall(html) if m != apk_name})
        check(f"{tag}: brak martwych nazw artefaktu", not obce_apk, f"obce: {obce_apk}")

    print()
    print("WYNIK:", "PASS (ad-hoc, nie suite)" if not fails else f"FAIL {fails}")
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main())

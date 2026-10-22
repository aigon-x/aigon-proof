#!/usr/bin/env python3
"""Inwentarz bramek: co istnieje vs co jest REALNIE wołane — per warstwa dostawy.

Odpowiada na pytanie „czy na pewno 100% bramek jest podpięte, w każdej warstwie".
Dla każdej bramki (zestaw testów, skrypt gate/check/verify) wypisuje, które
warstwy ją wołają, i listuje SIEROTY per warstwa.

Użycie:
    python3 gate_layer_inventory.py [KORZEŃ_REPO]

Dostosuj LAYERS i GLOBS do projektu. Zero zależności zewnętrznych.
"""
import glob
import os
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
os.chdir(ROOT)

# Warstwa -> pliki, które mogą wołać bramkę. Dodaj/usuń wg projektu.
LAYERS = {
    "build": ["scripts/build.sh"],
    "release": ["scripts/release.sh"],
    "deploy": ["scripts/ci-local.sh"],
    "CI": glob.glob(".github/workflows/*.yml") + glob.glob(".github/workflows/*.yaml"),
    "pre-push": [".git/hooks/pre-push"],
    "delivery": ["scripts/verify-delivery.py"],
}

# Co liczymy jako bramkę. Rozszerz globy, jeśli projekt ma inne katalogi.
GATE_GLOBS = [
    "tests/*.lua",
    "tests/*.py",
    "tools/gates/**/*.sh",
    "tools/gates/**/*.py",
    "tools/verify/**/*.sh",
    "scripts/check_*.py",
]


def read_all(paths):
    blob = ""
    for p in paths:
        try:
            with open(p, encoding="utf-8", errors="ignore") as fh:
                blob += fh.read()
        except OSError:
            continue
    return blob


def main() -> int:
    texts = {layer: read_all(files) for layer, files in LAYERS.items()}

    gates = []
    for pattern in GATE_GLOBS:
        gates.extend(glob.glob(pattern, recursive=True))
    gates = sorted(set(gates))

    print(f"KORZEŃ: {ROOT}")
    print(f"BRAMEK NA DYSKU: {len(gates)}\n")

    orphans = []
    for gate in gates:
        base = os.path.basename(gate)
        hit = [layer for layer, blob in texts.items() if base in blob or gate in blob]
        if not hit:
            orphans.append(gate)
        print(f"{gate:<58} {','.join(hit) if hit else '*** NIGDZIE ***'}")

    print(f"\nSIEROTY (bramka istnieje, żadna warstwa jej nie woła): {len(orphans)}")
    for gate in orphans:
        print(f"  - {gate}")

    print("\nWARSTWY — czy w ogóle istnieją:")
    for layer, files in LAYERS.items():
        present = [f for f in files if os.path.exists(f)]
        state = "OK" if present else "BRAK PLIKU"
        print(f"  {layer:<10} {state:<10} {', '.join(present) if present else '-'}")

    # Kod wyjścia: 1 gdy jakakolwiek bramka jest sierotą LUB brakuje warstwy,
    # która w projekcie ma istnieć. Dopasuj do własnej bramki (albo użyj jako
    # raport, nie gate — wtedy zawsze 0).
    return 0 if not orphans else 1


if __name__ == "__main__":
    sys.exit(main())

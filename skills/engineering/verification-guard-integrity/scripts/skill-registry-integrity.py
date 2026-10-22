#!/usr/bin/env python3
# ═══════════════════════════════════════════════════════════════════════════
#  skill-registry-integrity.py — GATE: spójność rejestru skilli (wieloźródłowa)
#
#  Bramka FALSYFIKOWALNA: wstrzyknij skill poza kanonem albo duplikat nazwy →
#  exit 1. Trzy klasy naruszeń (zmierzone 2026-09-29 w /opt/PROD):
#    LUKA-3  kanon (/opt/PROD/skills/shared) UBOŻSZY niż kopie lokalne agentów
#            (brak testu „kanon ⊇ lokalne").
#    LUKA-4  skill w manifeście (config/agent-models.yaml → skills:->manifest:)
#            bez katalogu w kanonie → sync go nie dostarczy / usunie (PRUNE).
#    LUKA-5  DUPLIKAT nazwy skilla wewnątrz katalogu agenta → skill_view
#            odmawia wczytania („Refusing to guess"); nazwa = deterministyczne ID.
#
#  KONTRAKT:  exit 0 = PASS · exit 1 = FAIL (dowód: ścieżki) · exit 2 = błąd env.
#
#  Użycie:  skill-registry-integrity.py [--json] [--root DIR]
#    --root DIR  dodaje katalog testowy (do dowodu falsyfikowalności w izolacji)
#    AIGON_PROD_ROOT  nadpisuje korzeń repo (do testów bez tykania produkcji)
# ═══════════════════════════════════════════════════════════════════════════
import argparse
import json
import os
import re
import sys
from collections import defaultdict

HOME = os.path.expanduser("~")
REPO = os.environ.get("AIGON_PROD_ROOT",
                      os.path.dirname(os.path.dirname(os.path.dirname(
                          os.path.abspath(__file__)))))
CANON_DIR = os.path.join(REPO, "skills", "shared")
MANIFEST = os.path.join(REPO, "config", "agent-models.yaml")

AGENT_SKILL_DIRS = {
    "hermes": os.path.join(HOME, ".hermes", "skills"),
    "qwen":   os.path.join(HOME, ".qwen", "skills"),
    "claude": os.path.join(HOME, ".claude", "skills"),
    "codex":  os.path.join(HOME, ".codex", "skills"),
    "grok":   os.path.join(HOME, ".grok", "skills"),
}


def skill_dirs(root):
    """{nazwa_skilla: [ścieżki]} — nazwa = basename katalogu z SKILL.md."""
    out = defaultdict(list)
    if not os.path.isdir(root):
        return out
    for dirpath, _dirs, files in os.walk(root):
        if any(f.lower() == "skill.md" for f in files):
            out[os.path.basename(dirpath)].append(dirpath)
    return out


def load_manifest_skills(path):
    """Nazwy skilli z sekcji skills:->manifest: (klucze na indent 4)."""
    names = []
    if not os.path.isfile(path):
        return names
    in_m = False
    for line in open(path, encoding="utf-8", errors="replace"):
        s = line.strip()
        if re.match(r"^\s*manifest:", s):
            in_m = True
            continue
        if not in_m:
            continue
        if line and not line.startswith(" ") and not s.startswith("#"):
            in_m = False
            continue
        m = re.match(r"^    ([\w\-.]+):", line)
        if m and not s.startswith(("targets:", "source:", "enabled:")):
            names.append(m.group(1))
    return names


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--root", help="dodaj katalog testowy (dowód w izolacji)")
    args = ap.parse_args()
    if args.root:
        AGENT_SKILL_DIRS["__test__"] = args.root

    findings, errors = [], []
    canon = skill_dirs(CANON_DIR)
    if not canon:
        print("ENV: brak kanonu %s" % CANON_DIR, file=sys.stderr)
        return 2
    canon_names = set(canon)

    # LUKA-5: kolizje nazw wewnątrz jednego katalogu agenta
    for agent, root in AGENT_SKILL_DIRS.items():
        if args.root and agent != "__test__":
            continue
        if not os.path.isdir(root):
            continue
        dups = {n: p for n, p in skill_dirs(root).items() if len(p) > 1}
        if dups:
            errors.append("LUKA-5 duplikat nazwy w %s: %d nazw" % (agent, len(dups)))
            findings.append({"check": "nama_duplikat", "agent": agent,
                             "status": "fail", "detail": dups})

    # LUKA-3: kanon musi być NADZBIOREM lokalnych unikatów
    for agent, root in AGENT_SKILL_DIRS.items():
        if args.root and agent != "__test__":
            continue
        if not os.path.isdir(root):
            continue
        missing = sorted(set(skill_dirs(root)) - canon_names)
        if missing:
            errors.append("LUKA-3 %s: %d skilli poza kanonem" % (agent, len(missing)))
            findings.append({"check": "kanon_nie_nadzbior", "agent": agent,
                             "status": "fail", "brak_w_kanonie": missing})

    # LUKA-4: manifest == rejestracja
    manifest = load_manifest_skills(MANIFEST)
    if manifest:
        orphan = sorted(set(manifest) - canon_names)
        if orphan:
            errors.append("LUKA-4 manifest: %d skilli bez katalogu w kanonie" % len(orphan))
            findings.append({"check": "manifest_bez_rdzenia", "status": "fail",
                             "detail": orphan})
        unreg = sorted(canon_names - set(manifest))
        if unreg:
            findings.append({"check": "rdzen_bez_manifestu", "status": "warn",
                             "detail": unreg,
                             "note": "sync replikuje TYLKO z manifestu"})

    report = {"tool": "skill-registry-integrity.py", "canon": CANON_DIR,
              "canon_count": len(canon_names), "manifest_count": len(manifest),
              "findings": findings, "errors": errors,
              "verdict": "FAIL" if errors else "PASS"}
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        for f in findings:
            print("[%s] %s %s" % (f["status"].upper(), f["check"], f.get("agent", "")))
        for e in errors:
            print("[FAIL] %s" % e, file=sys.stderr)
        print("verdict: %s (kanon=%d, manifest=%d)" %
              (report["verdict"], len(canon_names), len(manifest)))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
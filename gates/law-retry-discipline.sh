#!/usr/bin/env bash
# tools/gates/law-retry-discipline.sh — S2-T5 RETRY DISCIPLINE.
#
# Ponowienie bez granicy to pętla, która pali zasób do wyczerpania. Zmierzone:
#   2026-09-24 — łańcuch fallbacków qwena + pętla ponowień = ~4,44 mln tokenów
#                DeepSeek w ~3 min, do „402 Insufficient Balance" (LAW-EGRESS-1);
#   2026-09-26 — ledger-warden: 63 oryginały -> 608 przejęć (brak limitu prób).
# Ta bramka zastępuje fasadę tools/verify/retry-bounds-check.sh (GATE-098), która
# sprawdzała tylko obecność napisu „G135" w macierzy pokrycia.
#
# Read-only, statyczna. Dwie reguły na skryptach shell w TRY_PATHS:
#   R1 `curl --retry N` z N > TRY_MAX_RETRY (domyślnie 10) — ponowienie bez rozsądnej granicy;
#   R2 pętla `until <cmd sieciowy>` bez licznika prób (seq/$((…+1))/-ge/-gt/-lt/attempt/tries)
#      — ponawia, dopóki zdalny się nie zgodzi, czyli w nieskończoność.
# Plus R3 (konfiguracja): ~/.qwen/settings.json `modelFallbacks` musi być pusty
#   (LAW-EGRESS-1 — fallback na płatny tor był mnożnikiem pętli ponowień).
# Linia z komentarzem `retry-ok:` = świadomy wyjątek z uzasadnieniem.
# exit 0 = PASS, 1 = FAIL/ERROR.
#
#   TRY_PATHS       katalogi do skanu (domyślnie scripts tools — względem korzenia)
#   TRY_ROOT        korzeń (domyślnie /srv/aigon)
#   TRY_MAX_RETRY   próg R1
#   TRY_QWEN_SETTINGS  plik dla R3 (pusty = pomiń)
set -uo pipefail
ROOT_DEF="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TRY_ROOT="${TRY_ROOT:-$ROOT_DEF}"
TRY_PATHS="${TRY_PATHS:-scripts tools}"
TRY_MAX_RETRY="${TRY_MAX_RETRY:-10}"
TRY_QWEN_SETTINGS="${TRY_QWEN_SETTINGS-$HOME/.qwen/settings.json}"

TRY_ROOT="$TRY_ROOT" TRY_PATHS="$TRY_PATHS" TRY_MAX_RETRY="$TRY_MAX_RETRY" \
TRY_QWEN_SETTINGS="$TRY_QWEN_SETTINGS" timeout 50 python3 - <<'PY'
import os, re, sys, json
root = os.environ["TRY_ROOT"]; mx = int(os.environ["TRY_MAX_RETRY"])
NET = re.compile(r'\b(curl|wget|ssh|scp|rsync|nc|psql|docker\s+(exec|pull|push)|git\s+(push|fetch|pull))\b')
COUNTER = re.compile(r'\bseq\b|\$\(\(\s*\w+\s*[+-]\s*1|\(\(\s*\w+\s*\+\+|-ge\b|-gt\b|-lt\b|-le\b|attempt|tries|retries|MAX_', re.I)
R1 = re.compile(r'--retry[ =](\d+)')
viol, scanned = [], 0
for p in os.environ["TRY_PATHS"].split():
    base = os.path.join(root, p)
    for dp, dn, fn in os.walk(base):
        dn[:] = [d for d in dn if d not in ('.git', 'node_modules', '__pycache__')]
        for f in fn:
            if not (f.endswith('.sh') or f.endswith('.bash')) or '.bak' in f:
                continue
            path = os.path.join(dp, f); rel = os.path.relpath(path, root)
            try: lines = open(path, errors='replace').read().split('\n')
            except Exception: continue
            scanned += 1
            for i, l in enumerate(lines):
                s = l.strip()
                if s.startswith('#') or 'retry-ok:' in l: continue
                m = R1.search(l)
                if m and int(m.group(1)) > mx:
                    viol.append(f"R1 {rel}:{i+1} curl --retry {m.group(1)} > {mx}")
                if re.match(r'until\b', s) and NET.search(s):
                    body = []
                    for j in range(i, min(i + 40, len(lines))):
                        body.append(lines[j])
                        if re.match(r'\s*done\b', lines[j]): break
                    if not COUNTER.search('\n'.join(body)):
                        viol.append(f"R2 {rel}:{i+1} until <sieć> bez licznika prób: {s[:90]}")
qs = os.environ.get("TRY_QWEN_SETTINGS", "")
if qs:
    try:
        fb = json.load(open(qs)).get("modelFallbacks", "")
        if fb not in ("", None, [], {}):
            viol.append(f"R3 {qs}: modelFallbacks niepuste ({type(fb).__name__}) — LAW-EGRESS-1")
    except FileNotFoundError:
        pass
    except Exception as e:
        viol.append(f"R3 {qs}: nieczytelny ({e.__class__.__name__})")
if scanned == 0:
    print("ERROR law-retry-discipline: 0 skryptów w zakresie (reason=EVIDENCE_MISSING)"); sys.exit(1)
for v in viol: print("  " + v)
if viol:
    print(f"FAIL law-retry-discipline: {len(viol)} naruszeń w {scanned} skryptach"); sys.exit(1)
print(f"PASS law-retry-discipline: {scanned} skryptów, ponowienia ograniczone")
PY
rc=$?; [[ $rc -eq 0 ]] && exit 0; exit 1

#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/cjk-output-clean.sh — gate cjk-output-clean (hook-runner)
#
#  KONTEKST (rozkaz Suwerena 2026-10-01): w czacie pojawila sie „cala strona
#  chinskich znaczkow" — token ideograficzny (U+3002) wciagniety przy
#  generowaniu wyszedl jako ciag CJK. Suweren nie toleruje tego w zadnym
#  materiale, ktory czyta.
#
#  Bramka skanuje PLIKI STAGED (to, co wlasnie wchodzi do repo) pod katem
#  znakow CJK i fullwidth. Zakres: dokumenty czytane przez ludzi
#  (.md/.txt/.html/.yaml/.json/.sh/.py/.ts/.tsx/.js).
#
#  UWAGA — dlaczego NIE skanujemy wszystkiego: w repo leza legalne zasoby
#  wielojezyczne (tlumaczenia, korpusy treningowe, dane wejsciowe). Bramka
#  celuje w DOKUMENTY, ktore Suweren czyta, i pomija katalogi danych.
#
#  Kontrakt: exit 0 = PASS, exit 1 = FAIL (CJK w dokumencie staged).
#  Wylacznik: AIGON_CJK_GATE_SKIP=1 (swiadome, jednorazowe).
#  Allowlist: tools/gates/cjk-output-clean-allowlist.txt (sciezka + powod).
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

[ "${AIGON_CJK_GATE_SKIP:-0}" = "1" ] && { echo "cjk-output-clean: SKIP (AIGON_CJK_GATE_SKIP=1)"; exit 0; }

ALLOWLIST="$ROOT/tools/gates/cjk-output-clean-allowlist.txt"

# 1. Pliki staged (to, co wejdzie do commita)
STAGED=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null)
[ -z "$STAGED" ] && { echo "cjk-output-clean: PASS (brak plikow staged)"; exit 0; }

# 2. Tylko dokumenty/tekst czytany przez ludzi + katalogi danych wylaczone
DOCS=$(printf '%s\n' "$STAGED" | grep -E '\.(md|txt|html|htm|yaml|yml|json|sh|py|ts|tsx|js|jsx|conf|css)$' 2>/dev/null \
  | grep -vE '^(_data|data|corpus|datasets|vendor|node_modules|\.archive|runtime/knowledge/(corpus|datasets))/' 2>/dev/null)

[ -z "$DOCS" ] && { echo "cjk-output-clean: PASS (brak dokumentow staged do skanu)"; exit 0; }

# 3. Allowlist
if [ -f "$ALLOWLIST" ]; then
  DOCS=$(printf '%s\n' "$DOCS" | grep -vxF -f <(grep -vE '^\s*(#|$)' "$ALLOWLIST" 2>/dev/null) 2>/dev/null)
fi
[ -z "$DOCS" ] && { echo "cjk-output-clean: PASS (wszystkie staged na allowliscie)"; exit 0; }

# 4. Skan: bloki CJK + fullwidth. Realizacja: python3 (jeden przebieg, bez
#    N procesow grep). Cyrylica/grecka NIE sa blokowane (bywaja w materialach
#    naukowych); fullwidth TAK (prawie zawsze przeciek tokenizacji).
VIOL=$(printf '%s\n' "$DOCS" | python3 -c '
import sys, re, os
pat = re.compile("[\u3000-\u303f\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\uff00-\uffef\uac00-\ud7af]")
bad = False
for line in sys.stdin:
    f = line.rstrip("\n")
    if not f or not os.path.isfile(f):
        continue
    try:
        with open(f, encoding="utf-8", errors="replace") as fh:
            for n, l in enumerate(fh, 1):
                for m in pat.finditer(l):
                    ch = m.group(0)
                    print(f"{f}:{n}: U+{ord(ch):04X} {ch!r}  {l.strip()[:100]}")
                    bad = True
    except Exception as e:
        print(f"{f}: BLAD ODCZYTU: {e}")
sys.exit(1 if bad else 0)
')
RC=$?

if [ $RC -eq 0 ]; then
  echo "cjk-output-clean: PASS (brak znakow CJK w dokumentach staged)"
  exit 0
fi

echo "cjk-output-clean: FAIL — znaki CJK/fullwidth w dokumentach staged:"
printf '%s\n' "$VIOL" | head -25
echo "  Napraw: usun znaki (sa widoczne jako U+XXXX powyzej) albo dopisz"
echo "  sciezke do tools/gates/cjk-output-clean-allowlist.txt z uzasadnieniem."
exit 1
